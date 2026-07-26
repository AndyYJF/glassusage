/**
 * Self-drawn title bar. The native frame is off so the acrylic backdrop can reach the
 * top edge; everything here is ordinary DOM with `-webkit-app-region` doing the dragging.
 */
import { Minus, PictureInPicture2, Square, X } from "lucide-react";
import { api } from "../../lib/api";
import { useLiveRates } from "../../lib/hooks";
import { rate, usd } from "../../lib/format";

function ControlButton({
  onClick,
  label,
  danger,
  children,
}: {
  onClick: () => void;
  label: string;
  danger?: boolean;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      aria-label={label}
      title={label}
      onClick={onClick}
      className={`no-drag grid h-8 w-11 place-items-center rounded-lg text-[rgb(var(--text-dim))] transition-colors ${
        danger
          ? "hover:bg-[rgb(var(--danger)/0.85)] hover:text-white"
          : "hover:bg-white/10 hover:text-[rgb(var(--text))]"
      }`}
    >
      {children}
    </button>
  );
}

export function TitleBar() {
  const { data: live } = useLiveRates(2000);
  const active = (live?.tpm ?? 0) > 0;

  return (
    <header className="drag-region flex h-11 shrink-0 items-center gap-3 pl-4 pr-1.5">
      <div className="flex items-center gap-2.5">
        <div className="grid h-[18px] w-[18px] place-items-center rounded-[6px] bg-gradient-to-br from-[rgb(var(--accent))] to-[rgb(var(--accent-2))] shadow-[0_2px_6px_rgb(0_0_0/0.3)]">
          <div className="h-[7px] w-[7px] rounded-full bg-white/85" />
        </div>
        <span className="text-[0.8125rem] font-semibold tracking-tight">GlassUsage</span>
      </div>

      {/* Live pill: a persistent, glanceable answer to "is anything running right now". */}
      <div className="chip no-drag ml-1 gap-2">
        <span className={`status-dot ${active ? "status-live" : "status-missing"}`} />
        <span className="tnum">{rate(live?.tpm ?? 0)} tok/min</span>
        <span className="text-[rgb(var(--text-faint))]">·</span>
        <span className="tnum">{usd(live?.costToday ?? 0)} today</span>
      </div>

      <div className="ml-auto flex items-center gap-0.5">
        <ControlButton label="Mini card" onClick={() => api.toggleWidgetMode(true)}>
          <PictureInPicture2 size={15} strokeWidth={2} />
        </ControlButton>
        <ControlButton label="Minimize" onClick={() => api.minimize("main")}>
          <Minus size={16} strokeWidth={2} />
        </ControlButton>
        <ControlButton label="Maximize" onClick={() => api.toggleMaximize("main")}>
          <Square size={12} strokeWidth={2.2} />
        </ControlButton>
        {/* Closing hides to the tray; Quit lives in the tray menu and Settings. */}
        <ControlButton label="Close to tray" danger onClick={() => api.closeWindow("main")}>
          <X size={16} strokeWidth={2} />
        </ControlButton>
      </div>
    </header>
  );
}
