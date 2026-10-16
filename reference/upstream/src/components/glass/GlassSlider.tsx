/**
 * Apple-style linear glass slider.
 *
 * The refraction is entirely CSS: `backdrop-filter: url(#lens-pill)` re-samples the
 * backdrop wherever the thumb currently is, so dragging updates the lens for free. The
 * jelly stretch is a width transition on the thumb — because the displacement map is
 * stretched with the element, a wider thumb automatically produces an elliptical lens.
 * No JavaScript ever touches the SVG filter.
 */
import { useCallback, useEffect, useId, useRef, useState } from "react";
import { AnimatePresence, motion } from "framer-motion";
import clsx from "clsx";

interface Props {
  value: number;
  min?: number;
  max?: number;
  step?: number;
  onChange: (value: number) => void;
  onCommit?: (value: number) => void;
  format?: (value: number) => string;
  label?: string;
  disabled?: boolean;
  className?: string;
}

/** Distance the whole control slides when dragged past an end, before it springs back. */
const RUBBER_BAND_MAX = 4;

export function GlassSlider({
  value,
  min = 0,
  max = 100,
  step = 1,
  onChange,
  onCommit,
  format,
  label,
  disabled,
  className,
}: Props) {
  const trackRef = useRef<HTMLDivElement>(null);
  const [dragging, setDragging] = useState(false);
  const [overscroll, setOverscroll] = useState(0);
  const id = useId();

  const ratio = max > min ? (value - min) / (max - min) : 0;
  const pct = Math.max(0, Math.min(1, ratio)) * 100;

  const valueFromClientX = useCallback(
    (clientX: number) => {
      const el = trackRef.current;
      if (!el) return value;
      const rect = el.getBoundingClientRect();
      const raw = (clientX - rect.left) / rect.width;
      const clamped = Math.max(0, Math.min(1, raw));
      const next = min + clamped * (max - min);
      const snapped = step > 0 ? Math.round(next / step) * step : next;
      return Math.max(min, Math.min(max, Number(snapped.toFixed(6))));
    },
    [max, min, step, value],
  );

  /** Damped travel past the ends, the iOS rubber-band detail. */
  const overscrollFromClientX = useCallback((clientX: number) => {
    const el = trackRef.current;
    if (!el) return 0;
    const rect = el.getBoundingClientRect();
    if (clientX < rect.left) {
      return -Math.min(RUBBER_BAND_MAX, (rect.left - clientX) * 0.18);
    }
    if (clientX > rect.right) {
      return Math.min(RUBBER_BAND_MAX, (clientX - rect.right) * 0.18);
    }
    return 0;
  }, []);

  const handlePointerDown = (e: React.PointerEvent) => {
    if (disabled) return;
    e.currentTarget.setPointerCapture(e.pointerId);
    setDragging(true);
    onChange(valueFromClientX(e.clientX));
  };

  const handlePointerMove = (e: React.PointerEvent) => {
    if (!dragging || disabled) return;
    onChange(valueFromClientX(e.clientX));
    setOverscroll(overscrollFromClientX(e.clientX));
  };

  const endDrag = (e: React.PointerEvent) => {
    if (!dragging) return;
    e.currentTarget.releasePointerCapture?.(e.pointerId);
    setDragging(false);
    setOverscroll(0);
    onCommit?.(value);
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (disabled) return;
    const big = (max - min) / 10;
    const deltas: Record<string, number> = {
      ArrowLeft: -step,
      ArrowDown: -step,
      ArrowRight: step,
      ArrowUp: step,
      PageDown: -big,
      PageUp: big,
    };
    if (e.key === "Home") {
      e.preventDefault();
      onChange(min);
      onCommit?.(min);
      return;
    }
    if (e.key === "End") {
      e.preventDefault();
      onChange(max);
      onCommit?.(max);
      return;
    }
    const delta = deltas[e.key];
    if (delta === undefined) return;
    e.preventDefault();
    const next = Math.max(min, Math.min(max, Number((value + delta).toFixed(6))));
    onChange(next);
    onCommit?.(next);
  };

  // A pointer released outside the window would otherwise leave the thumb stretched.
  useEffect(() => {
    if (!dragging) return;
    const cancel = () => {
      setDragging(false);
      setOverscroll(0);
    };
    window.addEventListener("pointercancel", cancel);
    window.addEventListener("blur", cancel);
    return () => {
      window.removeEventListener("pointercancel", cancel);
      window.removeEventListener("blur", cancel);
    };
  }, [dragging]);

  const display = format ? format(value) : String(value);

  return (
    <motion.div
      ref={trackRef}
      className={clsx("gslider no-drag", dragging && "dragging", className)}
      role="slider"
      tabIndex={disabled ? -1 : 0}
      aria-label={label}
      aria-valuemin={min}
      aria-valuemax={max}
      aria-valuenow={value}
      aria-valuetext={display}
      aria-disabled={disabled}
      aria-labelledby={label ? undefined : id}
      onPointerDown={handlePointerDown}
      onPointerMove={handlePointerMove}
      onPointerUp={endDrag}
      onKeyDown={handleKeyDown}
      // Spring back from the rubber band on release.
      animate={{ x: overscroll }}
      transition={{ type: "spring", stiffness: 400, damping: 22 }}
      style={{ opacity: disabled ? 0.45 : 1 }}
    >
      <div className="gslider-track" />
      <div className="gslider-fill" style={{ width: `${pct}%` }} />
      <div className="gslider-thumb" style={{ left: `${pct}%` }}>
        <AnimatePresence>
          {dragging && (
            <motion.div
              className="gslider-bubble tnum"
              initial={{ opacity: 0, y: 6 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: 6 }}
              transition={{ duration: 0.12 }}
            >
              {display}
            </motion.div>
          )}
        </AnimatePresence>
      </div>
    </motion.div>
  );
}
