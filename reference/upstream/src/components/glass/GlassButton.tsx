import { forwardRef } from "react";
import clsx from "clsx";

interface Props extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  tone?: "default" | "accent" | "danger" | "ghost";
  size?: "sm" | "md";
}

export const GlassButton = forwardRef<HTMLButtonElement, Props>(function GlassButton(
  { tone = "default", size = "md", className, children, ...rest },
  ref,
) {
  return (
    <button
      ref={ref}
      type="button"
      className={clsx(
        "gbtn no-drag",
        tone === "accent" && "gbtn-accent",
        tone === "danger" && "gbtn-danger",
        tone === "ghost" && "gbtn-ghost",
        size === "sm" && "px-2.5 py-1 text-[0.75rem]",
        className,
      )}
      {...rest}
    >
      {children}
    </button>
  );
});
