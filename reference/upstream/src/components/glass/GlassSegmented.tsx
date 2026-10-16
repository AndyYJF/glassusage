/**
 * Segmented control. The lit thumb is a single element shared across options via
 * framer-motion's `layoutId`, so switching tabs slides the glass rather than
 * cross-fading two rectangles.
 */
import { useId } from "react";
import { motion } from "framer-motion";
import clsx from "clsx";

export interface SegmentOption<T extends string> {
  value: T;
  label: string;
  icon?: React.ReactNode;
}

interface Props<T extends string> {
  options: SegmentOption<T>[];
  value: T;
  onChange: (value: T) => void;
  className?: string;
  size?: "sm" | "md";
}

export function GlassSegmented<T extends string>({
  options,
  value,
  onChange,
  className,
  size = "md",
}: Props<T>) {
  // Scopes the layout animation so two segmented controls on one page don't
  // hand their thumbs to each other.
  const groupId = useId();

  const move = (dir: 1 | -1) => {
    const i = options.findIndex((o) => o.value === value);
    if (i < 0) return;
    const next = options[(i + dir + options.length) % options.length];
    onChange(next.value);
  };

  return (
    <div
      className={clsx("gseg no-drag", className)}
      role="tablist"
      onKeyDown={(e) => {
        if (e.key === "ArrowRight") {
          e.preventDefault();
          move(1);
        } else if (e.key === "ArrowLeft") {
          e.preventDefault();
          move(-1);
        }
      }}
    >
      {options.map((opt) => {
        const active = opt.value === value;
        return (
          <button
            key={opt.value}
            type="button"
            role="tab"
            aria-selected={active}
            tabIndex={active ? 0 : -1}
            data-active={active}
            className={clsx("gseg-item", size === "sm" && "px-2.5 py-1 text-[0.7rem]")}
            onClick={() => onChange(opt.value)}
          >
            {active && (
              <motion.span
                layoutId={`seg-thumb-${groupId}`}
                className="gseg-thumb"
                style={{ left: 0, right: 0, top: 0, bottom: 0, position: "absolute" }}
                transition={{ type: "tween", duration: 0.18, ease: [0.22, 1, 0.36, 1] }}
              />
            )}
            <span className="relative z-[1] inline-flex items-center gap-1.5">
              {opt.icon}
              {opt.label}
            </span>
          </button>
        );
      })}
    </div>
  );
}
