import { forwardRef } from "react";
import clsx from "clsx";

interface Props extends React.HTMLAttributes<HTMLDivElement> {
  /**
   * "lens" spends a displacement filter and is budgeted to primary surfaces only;
   * "plain" is blur + saturation, cheap enough for list rows and repeated chips.
   */
  variant?: "lens" | "plain" | "quiet";
  interactive?: boolean;
  padded?: boolean;
}

export const GlassCard = forwardRef<HTMLDivElement, Props>(function GlassCard(
  { variant = "plain", interactive, padded = true, className, children, ...rest },
  ref,
) {
  return (
    <div
      ref={ref}
      className={clsx(
        variant === "lens" && "glass-lens",
        variant === "plain" && "glass",
        variant === "quiet" && "glass-quiet",
        interactive && "interactive",
        padded && "p-4",
        className,
      )}
      {...rest}
    >
      {children}
    </div>
  );
});
