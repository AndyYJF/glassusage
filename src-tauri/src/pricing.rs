//! Model price table and cost computation.
//!
//! Prices come from LiteLLM's public `model_prices_and_context_window.json`, cached on
//! disk for 24h with a small compiled-in snapshot as the offline fallback. User overrides
//! from Settings always win.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use anyhow::Result;
use parking_lot::RwLock;
use serde::{Deserialize, Serialize};

const LITELLM_URL: &str =
    "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json";
const CACHE_TTL_MS: i64 = 24 * 60 * 60 * 1000;

/// Compiled-in prices so a first run with no network still costs correctly for the
/// models these agents actually use.
const FALLBACK: &str = include_str!("../assets/pricing-fallback.json");

#[derive(Debug, Clone, Copy, Default, Serialize, Deserialize)]
pub struct ModelPrice {
    #[serde(default)]
    pub input_cost_per_token: f64,
    #[serde(default)]
    pub output_cost_per_token: f64,
    #[serde(default)]
    pub cache_creation_input_token_cost: f64,
    #[serde(default)]
    pub cache_read_input_token_cost: f64,
}

#[derive(Default)]
struct Table {
    prices: HashMap<String, ModelPrice>,
    overrides: HashMap<String, ModelPrice>,
    /// Manual `raw model name -> canonical name` mappings, e.g. Antigravity placeholders.
    aliases: HashMap<String, String>,
    fetched_at_ms: i64,
    source_label: String,
}

pub struct Pricing {
    table: RwLock<Table>,
    cache_path: PathBuf,
    overrides_path: PathBuf,
}

/// Sources that report authoritative money amounts, which must not be overwritten by the
/// estimated price table.
pub fn source_has_native_cost(source: &str) -> bool {
    matches!(
        source,
        crate::model::source::CURSOR | crate::model::source::HERMES
    )
}

impl Pricing {
    pub fn new(data_dir: &Path) -> Self {
        let p = Self {
            table: RwLock::new(Table::default()),
            cache_path: data_dir.join("pricing-cache.json"),
            overrides_path: data_dir.join("pricing_overrides.json"),
        };
        p.load_from_disk();
        p
    }

    fn load_from_disk(&self) {
        let mut t = self.table.write();
        t.aliases = builtin_aliases();

        let cached = std::fs::read_to_string(&self.cache_path).ok().filter(|_| {
            std::fs::metadata(&self.cache_path)
                .and_then(|m| m.modified())
                .ok()
                .and_then(|m| m.elapsed().ok())
                .map(|age| (age.as_millis() as i64) < CACHE_TTL_MS)
                .unwrap_or(false)
        });

        let (json, label) = match cached {
            Some(c) => (c, "cache".to_string()),
            None => (FALLBACK.to_string(), "builtin".to_string()),
        };
        t.prices = merge_over_fallback(parse_litellm(&json));
        t.source_label = label;

        if let Ok(s) = std::fs::read_to_string(&self.overrides_path) {
            t.overrides = serde_json::from_str(&s).unwrap_or_default();
        }
    }

    /// Refresh from LiteLLM. Failure is non-fatal: the previous table stays in place.
    pub async fn refresh(&self) -> Result<usize> {
        let body = reqwest::Client::builder()
            .user_agent("GlassUsage/0.1 (+https://github.com/)")
            .timeout(std::time::Duration::from_secs(20))
            .build()?
            .get(LITELLM_URL)
            .send()
            .await?
            .error_for_status()?
            .text()
            .await?;

        let parsed = parse_litellm(&body);
        if parsed.is_empty() {
            anyhow::bail!("price table parsed to zero entries");
        }
        std::fs::write(&self.cache_path, &body).ok();
        let merged = merge_over_fallback(parsed);
        let n = merged.len();
        let mut t = self.table.write();
        t.prices = merged;
        t.fetched_at_ms = crate::store::now_ms();
        t.source_label = "litellm".into();
        Ok(n)
    }

    pub fn set_overrides(&self, overrides: HashMap<String, ModelPrice>) -> Result<()> {
        let mut t = self.table.write();
        for (k, v) in overrides {
            t.overrides.insert(k, v);
        }
        std::fs::write(
            &self.overrides_path,
            serde_json::to_string_pretty(&t.overrides)?,
        )?;
        Ok(())
    }

    /// Drop one override and persist. Returns whether anything was removed.
    pub fn remove_override(&self, model: &str) -> Result<bool> {
        let mut t = self.table.write();
        let removed = t.overrides.remove(model).is_some();
        if removed {
            std::fs::write(
                &self.overrides_path,
                serde_json::to_string_pretty(&t.overrides)?,
            )?;
        }
        Ok(removed)
    }

    pub fn overrides(&self) -> HashMap<String, ModelPrice> {
        self.table.read().overrides.clone()
    }

    pub fn table_info(&self) -> (usize, String) {
        let t = self.table.read();
        (t.prices.len(), t.source_label.clone())
    }

    /// Resolve a raw model string to the canonical billing name used for grouping.
    pub fn normalize(&self, raw: &str) -> String {
        let t = self.table.read();
        normalize_with(&t, raw).unwrap_or_else(|| simplify(raw))
    }

    pub fn price_for(&self, model_norm: &str) -> Option<ModelPrice> {
        let t = self.table.read();
        t.overrides
            .get(model_norm)
            .copied()
            .or_else(|| t.prices.get(model_norm).copied())
            // Existing rows keep their original model_norm; aliases still have to resolve
            // at pricing time or a later reprice would leave them unpriced forever.
            .or_else(|| {
                t.aliases
                    .get(model_norm)
                    .and_then(|alias| t.overrides.get(alias).or_else(|| t.prices.get(alias)))
                    .copied()
            })
    }

    /// Cost in USD, or `None` when the model has no price entry (rendered greyed out).
    pub fn cost(
        &self,
        model_norm: &str,
        input: i64,
        output: i64,
        cache_read: i64,
        cache_write: i64,
    ) -> Option<f64> {
        let p = self.price_for(model_norm)?;
        // A missing cache price is not evidence that a vendor follows Anthropic's cache
        // multipliers. Mark rows with such cache usage unpriced instead of silently
        // manufacturing a precise-looking amount.
        if (cache_write > 0 && p.cache_creation_input_token_cost <= 0.0)
            || (cache_read > 0 && p.cache_read_input_token_cost <= 0.0)
        {
            return None;
        }
        let cw = p.cache_creation_input_token_cost;
        let cr = p.cache_read_input_token_cost;
        Some(
            input as f64 * p.input_cost_per_token
                + output as f64 * p.output_cost_per_token
                + cache_write as f64 * cw
                + cache_read as f64 * cr,
        )
    }
}

/// Layered lookup: exact -> provider-prefix stripped -> dot/dash version swap -> alias
/// table -> fuzzy prefix match. Returns `None` when nothing matches.
fn normalize_with(t: &Table, raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    let known = |k: &str| t.overrides.contains_key(k) || t.prices.contains_key(k);

    let lower = raw.to_ascii_lowercase();
    if known(&lower) {
        return Some(lower);
    }

    if let Some(alias) = t.aliases.get(&lower) {
        if known(alias) {
            return Some(alias.clone());
        }
    }

    // Strip a provider prefix ("anthropic/claude-...", "openai/gpt-...").
    let stripped = lower.rsplit('/').next().unwrap_or(&lower).to_string();
    if known(&stripped) {
        return Some(stripped);
    }
    if let Some(alias) = t.aliases.get(&stripped) {
        if known(alias) {
            return Some(alias.clone());
        }
    }

    // Version separator variants: claude-3-5-sonnet <-> claude-3.5-sonnet.
    for cand in version_variants(&stripped) {
        if known(&cand) {
            return Some(cand);
        }
    }

    // Trailing date stamps and vendor suffixes: claude-sonnet-4-20250514 -> claude-sonnet-4.
    let trimmed = strip_date_suffix(&stripped);
    if trimmed != stripped && known(&trimmed) {
        return Some(trimmed);
    }

    // Longest known family that the raw name extends. Do not match in the reverse
    // direction: a generic raw name such as "gpt-4" must not be assigned an arbitrary,
    // potentially more expensive variant.
    let mut best: Option<&String> = None;
    for key in t.prices.keys() {
        if key.len() >= 6
            && stripped.starts_with(key.as_str())
            && best.map_or(true, |b| key.len() > b.len())
        {
            best = Some(key);
        }
    }
    best.cloned()
}

fn version_variants(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    if s.contains('.') {
        out.push(s.replace('.', "-"));
    }
    // "3-5-sonnet" -> "3.5-sonnet"
    let bytes: Vec<char> = s.chars().collect();
    let mut swapped = String::new();
    let mut i = 0;
    while i < bytes.len() {
        if i + 2 < bytes.len()
            && bytes[i].is_ascii_digit()
            && bytes[i + 1] == '-'
            && bytes[i + 2].is_ascii_digit()
        {
            swapped.push(bytes[i]);
            swapped.push('.');
            i += 2;
        } else {
            swapped.push(bytes[i]);
            i += 1;
        }
    }
    if swapped != s {
        out.push(swapped);
    }
    out
}

fn strip_date_suffix(s: &str) -> String {
    let parts: Vec<&str> = s.split('-').collect();
    if let Some(last) = parts.last() {
        if last.len() >= 6 && last.chars().all(|c| c.is_ascii_digit()) {
            return parts[..parts.len() - 1].join("-");
        }
    }
    s.to_string()
}

/// Best-effort display name when no price entry exists at all.
fn simplify(raw: &str) -> String {
    let s = raw.trim().to_ascii_lowercase();
    if s.is_empty() {
        return "unknown".into();
    }
    s.rsplit('/').next().unwrap_or(&s).to_string()
}

/// Layer a fetched table over the compiled-in one.
///
/// The bundled snapshot covers models these agents use that LiteLLM has not published, so
/// it stays underneath every refresh. Without this, a successful fetch would *remove* those
/// prices, and the reprice pass would then overwrite already-computed costs with NULL.
fn merge_over_fallback(fetched: HashMap<String, ModelPrice>) -> HashMap<String, ModelPrice> {
    let mut out = parse_litellm(FALLBACK);
    out.extend(fetched);
    out
}

fn parse_litellm(json: &str) -> HashMap<String, ModelPrice> {
    let root: serde_json::Value = match serde_json::from_str(json) {
        Ok(v) => v,
        Err(_) => return HashMap::new(),
    };
    let obj = match root.as_object() {
        Some(o) => o,
        None => return HashMap::new(),
    };
    let mut out = HashMap::with_capacity(obj.len());
    for (name, val) in obj {
        if name == "sample_spec" || name.starts_with('_') {
            continue;
        }
        let get = |k: &str| val.get(k).and_then(|v| v.as_f64()).unwrap_or(0.0);
        let price = ModelPrice {
            input_cost_per_token: get("input_cost_per_token"),
            output_cost_per_token: get("output_cost_per_token"),
            cache_creation_input_token_cost: get("cache_creation_input_token_cost"),
            cache_read_input_token_cost: get("cache_read_input_token_cost"),
        };
        if price.input_cost_per_token == 0.0 && price.output_cost_per_token == 0.0 {
            continue;
        }
        let key = name.to_ascii_lowercase();
        // LiteLLM keys are often "vertex_ai/claude-...", index both forms.
        if let Some(bare) = key.rsplit('/').next() {
            out.entry(bare.to_string()).or_insert(price);
        }
        out.insert(key, price);
    }
    out
}

/// Names that no price table will ever contain, mapped to their real billing model.
fn builtin_aliases() -> HashMap<String, String> {
    [
        // Antigravity exposes routing labels rather than model ids.
        ("gemini-pro-default", "gemini-2.5-pro"),
        ("gemini-pro-c", "gemini-2.5-pro"),
        ("gemini-pro-high", "gemini-2.5-pro"),
        ("gemini-flash-default", "gemini-2.5-flash"),
        ("gemini-3-flash-e", "gemini-3-flash"),
        ("gemini-3-flash-a", "gemini-3-flash"),
        ("gemini-3.1-pro-low", "gemini-3-pro-preview"),
        ("gemini-3.1-pro", "gemini-3-pro-preview"),
        ("claude-opus-4-6-thinking", "claude-opus-4-1"),
        ("claude-sonnet-4-5-thinking", "claude-sonnet-4-5"),
        // Cursor's dashboard uses short display names.
        ("claude-4-sonnet", "claude-sonnet-4-20250514"),
        ("claude-4-opus", "claude-opus-4-20250514"),
        ("gpt-5", "gpt-5-2025-08-07"),
        ("glm-latest", "glm-5.2"),
        ("auto", "unknown"),
    ]
    .into_iter()
    .map(|(a, b)| (a.to_string(), b.to_string()))
    .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn table(pairs: &[(&str, f64, f64)]) -> Table {
        Table {
            prices: pairs
                .iter()
                .map(|(k, i, o)| {
                    (
                        k.to_string(),
                        ModelPrice {
                            input_cost_per_token: *i,
                            output_cost_per_token: *o,
                            ..Default::default()
                        },
                    )
                })
                .collect(),
            aliases: builtin_aliases(),
            ..Default::default()
        }
    }

    #[test]
    fn normalizes_through_each_layer() {
        let t = table(&[
            ("claude-sonnet-4", 1.0, 2.0),
            ("gpt-5-2025-08-07", 1.0, 2.0),
            ("gemini-2.5-pro", 1.0, 2.0),
        ]);

        // Exact, case-insensitive.
        assert_eq!(
            normalize_with(&t, "Claude-Sonnet-4").as_deref(),
            Some("claude-sonnet-4")
        );
        // Provider prefix stripped.
        assert_eq!(
            normalize_with(&t, "anthropic/claude-sonnet-4").as_deref(),
            Some("claude-sonnet-4")
        );
        // Trailing date stamp dropped.
        assert_eq!(
            normalize_with(&t, "claude-sonnet-4-20250514").as_deref(),
            Some("claude-sonnet-4")
        );
        // Alias for a routing label that no price table carries.
        assert_eq!(
            normalize_with(&t, "gemini-pro-default").as_deref(),
            Some("gemini-2.5-pro")
        );
        // An alias only applies when its target is actually priced.
        assert_eq!(
            normalize_with(&table(&[("x-1234", 1.0, 1.0)]), "gemini-pro-default"),
            None
        );
    }

    #[test]
    fn unknown_model_has_no_price_rather_than_zero() {
        let t = table(&[("claude-sonnet-4", 1e-6, 2e-6)]);
        assert_eq!(normalize_with(&t, "some-unreleased-thing"), None);

        // `normalize` still yields a display name, but costing must decline to guess: a
        // fabricated 0.0 would read as "this was free".
        let dir = std::env::temp_dir().join("glassusage-pricing-test");
        std::fs::create_dir_all(&dir).unwrap();
        let p = Pricing {
            table: RwLock::new(t),
            cache_path: dir.join("cache.json"),
            overrides_path: dir.join("overrides.json"),
        };
        assert_eq!(
            p.normalize("some-unreleased-thing"),
            "some-unreleased-thing"
        );
        assert_eq!(p.cost("some-unreleased-thing", 1000, 1000, 0, 0), None);
    }

    #[test]
    fn cache_usage_without_explicit_rates_is_unpriced() {
        let dir = std::env::temp_dir().join("glassusage-pricing-test");
        std::fs::create_dir_all(&dir).unwrap();
        let p = Pricing {
            table: RwLock::new(table(&[("m", 10.0, 100.0)])),
            cache_path: dir.join("cache.json"),
            overrides_path: dir.join("overrides.json"),
        };
        assert_eq!(p.cost("m", 1, 1, 1, 1), None);
        assert_eq!(p.cost("m", 1, 1, 0, 0), Some(110.0));
    }

    #[test]
    fn overrides_beat_the_fetched_table() {
        let dir = std::env::temp_dir().join("glassusage-pricing-test");
        std::fs::create_dir_all(&dir).unwrap();
        let mut t = table(&[("m", 10.0, 10.0)]);
        t.overrides.insert(
            "m".into(),
            ModelPrice {
                input_cost_per_token: 1.0,
                output_cost_per_token: 1.0,
                ..Default::default()
            },
        );
        let p = Pricing {
            table: RwLock::new(t),
            cache_path: dir.join("cache.json"),
            overrides_path: dir.join("overrides.json"),
        };
        assert_eq!(p.cost("m", 1, 0, 0, 0), Some(1.0));
    }

    #[test]
    fn refresh_does_not_drop_models_only_the_fallback_knows() {
        let bundled = parse_litellm(FALLBACK);
        assert!(!bundled.is_empty(), "bundled snapshot must parse");
        let only_bundled = bundled.keys().next().unwrap().clone();

        // A fetched table that knows nothing must not erase the bundled prices, otherwise
        // the reprice pass would null out costs that were already correct.
        let merged = merge_over_fallback(HashMap::new());
        assert!(merged.contains_key(&only_bundled));

        // ...and where both know a model, the fetched value wins.
        let fetched: HashMap<String, ModelPrice> = [(
            only_bundled.clone(),
            ModelPrice {
                input_cost_per_token: 42.0,
                ..Default::default()
            },
        )]
        .into_iter()
        .collect();
        assert_eq!(
            merge_over_fallback(fetched)
                .get(&only_bundled)
                .unwrap()
                .input_cost_per_token,
            42.0
        );
    }

    #[test]
    fn free_models_are_not_indexed_as_priced() {
        // LiteLLM lists some entries with zero cost; treating those as "priced" would
        // report real usage as $0.00 instead of flagging it as unpriced.
        let parsed =
            parse_litellm(r#"{"free-thing":{"input_cost_per_token":0,"output_cost_per_token":0}}"#);
        assert!(parsed.is_empty());
    }
}
