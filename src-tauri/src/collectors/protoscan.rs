//! A minimal protobuf wire-format reader.
//!
//! Antigravity stores trajectory metadata as protobuf blobs with no published schema.
//! Decoding the wire format directly gives access to the token counters without needing
//! generated types, and unknown fields are simply ignored — which is exactly the
//! tolerance needed for a format that can change without notice.

#[derive(Debug, Clone)]
pub enum Value {
    Varint(u64),
    Fixed64(u64),
    Fixed32(u32),
    Bytes(Vec<u8>),
    Message(Message),
}

#[derive(Debug, Clone, Default)]
pub struct Message {
    pub fields: Vec<(u32, Value)>,
    /// Original bytes, kept for nested messages so a field that was speculatively
    /// parsed as a submessage can still be read back as a string.
    pub raw: Option<Vec<u8>>,
}

impl Message {
    pub fn get(&self, field: u32) -> Option<&Value> {
        self.fields.iter().find(|(n, _)| *n == field).map(|(_, v)| v)
    }

    pub fn get_all(&self, field: u32) -> impl Iterator<Item = &Value> {
        self.fields.iter().filter(move |(n, _)| *n == field).map(|(_, v)| v)
    }

    pub fn message(&self, field: u32) -> Option<&Message> {
        match self.get(field) {
            Some(Value::Message(m)) => Some(m),
            _ => None,
        }
    }

    /// Varint field as i64, defaulting to 0 for absent fields (proto3 semantics).
    pub fn varint(&self, field: u32) -> i64 {
        match self.get(field) {
            Some(Value::Varint(v)) => *v as i64,
            _ => 0,
        }
    }

    /// A length-delimited field interpreted as UTF-8, when it actually is UTF-8.
    pub fn string(&self, field: u32) -> Option<String> {
        match self.get(field) {
            Some(Value::Bytes(b)) => String::from_utf8(b.clone()).ok(),
            // A submessage whose bytes happened to parse as one still has the raw text.
            Some(Value::Message(m)) => m.raw.as_ref().and_then(|b| String::from_utf8(b.clone()).ok()),
            _ => None,
        }
    }

    /// Follow a chain of nested message fields.
    pub fn path(&self, fields: &[u32]) -> Option<&Message> {
        let mut cur = self;
        for f in fields {
            cur = cur.message(*f)?;
        }
        Some(cur)
    }
}

impl Message {
    fn with_raw(mut self, raw: Vec<u8>) -> Self {
        self.raw = Some(raw);
        self
    }
}

pub fn decode(buf: &[u8]) -> Option<Message> {
    decode_inner(buf, 0)
}

const MAX_DEPTH: u32 = 8;

fn decode_inner(buf: &[u8], depth: u32) -> Option<Message> {
    let mut msg = Message::default();
    let mut pos = 0usize;

    while pos < buf.len() {
        let (key, next) = read_varint(buf, pos)?;
        pos = next;
        let field_no = (key >> 3) as u32;
        let wire = (key & 7) as u8;
        if field_no == 0 {
            return None;
        }

        match wire {
            0 => {
                let (v, next) = read_varint(buf, pos)?;
                pos = next;
                msg.fields.push((field_no, Value::Varint(v)));
            }
            1 => {
                if pos + 8 > buf.len() {
                    return None;
                }
                let v = u64::from_le_bytes(buf[pos..pos + 8].try_into().ok()?);
                pos += 8;
                msg.fields.push((field_no, Value::Fixed64(v)));
            }
            5 => {
                if pos + 4 > buf.len() {
                    return None;
                }
                let v = u32::from_le_bytes(buf[pos..pos + 4].try_into().ok()?);
                pos += 4;
                msg.fields.push((field_no, Value::Fixed32(v)));
            }
            2 => {
                let (len, next) = read_varint(buf, pos)?;
                pos = next;
                let len = len as usize;
                if pos + len > buf.len() {
                    return None;
                }
                let sub = &buf[pos..pos + len];
                pos += len;
                // Length-delimited bytes are ambiguous: try parsing them as a nested
                // message and fall back to raw bytes when that fails.
                let value = if depth < MAX_DEPTH && len > 1 {
                    match decode_inner(sub, depth + 1) {
                        Some(m) => Value::Message(m.with_raw(sub.to_vec())),
                        None => Value::Bytes(sub.to_vec()),
                    }
                } else {
                    Value::Bytes(sub.to_vec())
                };
                msg.fields.push((field_no, value));
            }
            // Groups (3/4) are deprecated and never appear here.
            _ => return None,
        }
    }
    Some(msg)
}

fn read_varint(buf: &[u8], mut pos: usize) -> Option<(u64, usize)> {
    let mut result: u64 = 0;
    let mut shift = 0u32;
    while pos < buf.len() {
        let b = buf[pos];
        pos += 1;
        result |= ((b & 0x7f) as u64) << shift;
        if b & 0x80 == 0 {
            return Some((result, pos));
        }
        shift += 7;
        if shift > 63 {
            return None;
        }
    }
    None
}
