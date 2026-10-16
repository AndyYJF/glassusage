import clsx from "clsx";

interface Props {
  checked: boolean;
  onChange: (checked: boolean) => void;
  disabled?: boolean;
  label?: string;
  className?: string;
}

export function GlassSwitch({ checked, onChange, disabled, label, className }: Props) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      data-on={checked}
      className={clsx("gswitch no-drag", className)}
      style={{ opacity: disabled ? 0.45 : 1 }}
      onClick={() => !disabled && onChange(!checked)}
    >
      <span className="gswitch-thumb" />
    </button>
  );
}
