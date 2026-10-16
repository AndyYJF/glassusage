import { useEffect } from "react";
import { AnimatePresence, motion } from "framer-motion";
import { AlertCircle, CheckCircle2 } from "lucide-react";
import { useUi } from "../../lib/store";

export function Toast() {
  const toast = useUi((s) => s.toast);
  const dismiss = useUi((s) => s.dismissToast);

  useEffect(() => {
    if (!toast) return;
    // Errors stay long enough to read a path or a stack line.
    const ms = toast.tone === "error" ? 6000 : 3000;
    const t = window.setTimeout(dismiss, ms);
    return () => window.clearTimeout(t);
  }, [toast, dismiss]);

  return (
    <div className="pointer-events-none fixed inset-x-0 bottom-5 z-50 flex justify-center">
      <AnimatePresence>
        {toast && (
          <motion.div
            key={toast.id}
            className="glass-lens pointer-events-auto flex max-w-[520px] items-start gap-2.5 px-4 py-2.5 text-[0.8125rem]"
            initial={{ opacity: 0, y: 16, scale: 0.96 }}
            animate={{ opacity: 1, y: 0, scale: 1 }}
            exit={{ opacity: 0, y: 10, scale: 0.97 }}
            transition={{ type: "spring", stiffness: 420, damping: 32 }}
            role="status"
            onClick={dismiss}
          >
            {toast.tone === "error" ? (
              <AlertCircle size={16} className="mt-px shrink-0 text-[rgb(var(--danger))]" />
            ) : (
              <CheckCircle2 size={16} className="mt-px shrink-0 text-[rgb(var(--success))]" />
            )}
            <span className="whitespace-pre-wrap">{toast.message}</span>
          </motion.div>
        )}
      </AnimatePresence>
    </div>
  );
}
