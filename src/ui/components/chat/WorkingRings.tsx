// The Ninjy "working" mark: the logo's two rings (white upper-left, gold lower-right,
// centres 26° apart, gold over white at the top crossing and white over gold at the
// bottom) draw in apart along that axis, slide together to interlock, hold, then fade.
// The first ring takes the text colour (white on dark, dark on light, like the logo's
// two versions). Geometry is traced from ninjy-glass-link-1024(2).png; the animation lives in
// styles.css (.working-rings*). Under prefers-reduced-motion the rings show still.
//
// The two short "over" arcs are cut out of the ring underneath with a stroke in the
// surface colour, so set --working-rings-gap when the mark sits on something other
// than the canvas.

export default function WorkingRings({ size = 16, label = '', className = '' }: { size?: number; label?: string; className?: string }) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      role={label ? 'img' : undefined}
      aria-label={label || undefined}
      aria-hidden={label ? undefined : true}
      className={`working-rings shrink-0 overflow-visible text-primary ${className}`}
    >
      <circle className="working-rings-ring working-rings-a" cx="9.14" cy="10.6" r="4.7" fill="none" stroke="currentColor" strokeWidth="2.34" />
      <path className="working-rings-over" d="M11.44 10.19 A4.7 4.7 0 0 1 15.94 8.82" fill="none" stroke="var(--working-rings-gap, var(--color-canvas))" strokeWidth="3.8" />
      <circle className="working-rings-ring working-rings-b" cx="14.88" cy="13.4" r="4.7" fill="none" stroke="var(--color-accent, #e8ba5a)" strokeWidth="2.34" />
      <path className="working-rings-over" d="M12.46 13.92 A4.7 4.7 0 0 1 7.92 15.14" fill="none" stroke="var(--working-rings-gap, var(--color-canvas))" strokeWidth="3.8" />
      <path className="working-rings-over" d="M12.46 13.92 A4.7 4.7 0 0 1 7.92 15.14" fill="none" stroke="currentColor" strokeWidth="2.34" />
    </svg>
  );
}
