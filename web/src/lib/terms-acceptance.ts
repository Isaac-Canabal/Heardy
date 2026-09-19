import { termsAcceptanceDays, termsVersion } from "@/content/downloads";

const storageKey = "heardy.termsAcceptance";

type StoredAcceptance = {
  version: string;
  acceptedAt: string;
};

function read(): StoredAcceptance | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = window.localStorage.getItem(storageKey);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<StoredAcceptance>;
    if (typeof parsed.version !== "string" || typeof parsed.acceptedAt !== "string") {
      return null;
    }
    return { version: parsed.version, acceptedAt: parsed.acceptedAt };
  } catch {
    return null;
  }
}

/** Aceptación vigente: misma versión de los términos y menos de N días. */
export function hasValidAcceptance(now: Date = new Date()): boolean {
  const stored = read();
  if (!stored || stored.version !== termsVersion) return false;
  const acceptedAt = Date.parse(stored.acceptedAt);
  if (Number.isNaN(acceptedAt)) return false;
  const ageMs = now.getTime() - acceptedAt;
  return ageMs >= 0 && ageMs < termsAcceptanceDays * 24 * 60 * 60 * 1000;
}

export function recordAcceptance(now: Date = new Date()): void {
  if (typeof window === "undefined") return;
  try {
    const value: StoredAcceptance = {
      version: termsVersion,
      acceptedAt: now.toISOString(),
    };
    window.localStorage.setItem(storageKey, JSON.stringify(value));
  } catch {
    // Sin localStorage (modo privado, bloqueo): simplemente se preguntará otra vez.
  }
}
