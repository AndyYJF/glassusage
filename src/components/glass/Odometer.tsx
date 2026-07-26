/**
 * Rolling numeric display.
 *
 * Each digit is a column of 0-9 translated vertically, so a value change rolls only the
 * digits that actually changed, like a mechanical counter. That is what keeps a live
 * counter readable instead of a blur of motion.
 *
 * Every character — digit or not — is laid out as a fixed `1em`-tall cell. An
 * `overflow: hidden` inline-block takes its baseline from its bottom edge, so mixing
 * clipped digit columns with ordinary text would drop the numbers below the `$` and `.`
 * beside them.
 */
import { motion, useReducedMotion } from "framer-motion";
import clsx from "clsx";

const DIGITS = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"];

function DigitColumn({ digit }: { digit: number }) {
  return (
    // 1ch is exactly the advance of "0", and tabular figures make every digit that wide.
    <span className="relative inline-block h-[1em] w-[1ch] overflow-hidden">
      <motion.span
        className="absolute left-0 top-0 flex w-full flex-col"
        animate={{ y: `${-digit}em` }}
        transition={{ duration: 0.28, ease: [0.22, 1, 0.36, 1] }}
      >
        {DIGITS.map((d) => (
          <span key={d} className="grid h-[1em] w-full place-items-center">
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
    <span className={clsx("tnum inline-flex h-[1em] items-center leading-none", className)}>
      {value.split("").map((ch, i) =>
        ch >= "0" && ch <= "9" ? (
          // Index keys are correct here: position in the number is the identity that
          // matters, so the hundreds column keeps rolling as the hundreds column.
          <DigitColumn key={i} digit={Number(ch)} />
        ) : (
          <span key={i} className="grid h-[1em] place-items-center">
            {ch}
          </span>
        ),
      )}
    </span>
  );
}
