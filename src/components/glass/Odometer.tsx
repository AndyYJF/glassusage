/**
 * Rolling numeric display.
 *
 * Each digit is a column of 0-9 translated vertically, so a value change rolls only the
 * digits that actually changed, like a mechanical counter. That is what keeps a live
 * counter readable instead of a blur of motion.
 *
 * Every glyph — digit or not — is a fixed `1em` cell with `overflow: hidden`. That keeps
 * the inline-flex baseline consistent: mixed `$` / `.` / digit boxes would otherwise sit
 * on different baselines and look vertically shifted next to each other.
 */
import { motion, useReducedMotion } from "framer-motion";
import clsx from "clsx";
import type { ReactNode } from "react";

const DIGITS = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"];

function GlyphCell({ children }: { children: ReactNode }) {
  // No fixed ch-width — `$`, `.`, `K/M` need their natural advance. overflow:hidden
  // still matches DigitColumn's baseline (bottom edge of the 1em box).
  return (
    <span className="relative block h-[1em] shrink-0 overflow-hidden leading-none">
      <span className="grid h-full place-items-center">{children}</span>
    </span>
  );
}

function DigitColumn({ digit }: { digit: number }) {
  return (
    // 1ch is exactly the advance of "0", and tabular figures make every digit that wide.
    <span className="relative block h-[1em] w-[1ch] shrink-0 overflow-hidden leading-none">
      <motion.span
        className="absolute left-0 top-0 flex w-full flex-col"
        animate={{ y: `${-digit}em` }}
        transition={{ duration: 0.28, ease: [0.22, 1, 0.36, 1] }}
      >
        {DIGITS.map((d) => (
          <span key={d} className="grid h-[1em] w-full place-items-center leading-none">
            {d}
          </span>
        ))}
      </motion.span>
    </span>
  );
}

interface Props {
  /** Pre-formatted text; any non-digit characters render statically. */
  value: string;
  className?: string;
}

export function Odometer({ value, className }: Props) {
  const reduced = useReducedMotion();

  if (reduced) {
    return <span className={clsx("tnum", className)}>{value}</span>;
  }

  return (
    <span
      className={clsx(
        "tnum inline-flex h-[1em] items-center leading-none align-top",
        className,
      )}
    >
      {value.split("").map((ch, i) =>
        ch >= "0" && ch <= "9" ? (
          // Index keys are correct here: position in the number is the identity that
          // matters, so the hundreds column keeps rolling as the hundreds column.
          <DigitColumn key={i} digit={Number(ch)} />
        ) : (
          <GlyphCell key={i}>{ch}</GlyphCell>
        ),
      )}
    </span>
  );
}
