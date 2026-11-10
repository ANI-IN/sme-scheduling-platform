/**
 * A small picture of how to copy a Discord ID: turn on Developer Mode once, then right click a
 * channel (or a person) and choose "Copy Channel ID" (or "Copy User ID").
 */
export function DiscordIdPicture({ kind = 'channel' }: { kind?: 'channel' | 'user' }) {
  const item = kind === 'channel' ? 'Copy Channel ID' : 'Copy User ID';
  const target = kind === 'channel' ? '# alerts' : 'Priya (you)';
  return (
    <details className="mt-1 text-sm">
      <summary className="cursor-pointer font-medium text-link">
        How do I copy a {kind === 'channel' ? 'channel' : 'user'} ID?
      </summary>
      <ol className="mt-2 list-decimal space-y-1 pl-5 text-muted-foreground">
        <li>
          In Discord, open User Settings (the gear next to your name), choose Advanced and turn on
          Developer Mode. You only do this once.
        </li>
        <li>
          Right click the {kind === 'channel' ? 'channel name' : 'person'} and choose {item}.
        </li>
        <li>Paste it here. It is a long number of 17 to 20 digits.</li>
      </ol>
      <svg
        role="img"
        aria-label={`A Discord menu after right clicking ${target}, with ${item} at the bottom`}
        viewBox="0 0 360 170"
        className="mt-3 w-full max-w-sm rounded-md border border-border"
      >
        <rect width="360" height="170" fill="#313338" />
        <rect x="12" y="14" width="150" height="26" rx="4" fill="#404249" />
        <text x="22" y="32" fill="#f2f3f5" fontSize="13" fontFamily="sans-serif">
          {target}
        </text>
        <circle cx="172" cy="27" r="11" fill="#5865f2" />
        <text x="168" y="31" fill="#fff" fontSize="12" fontFamily="sans-serif">
          1
        </text>
        <rect x="150" y="48" width="196" height="112" rx="6" fill="#111214" />
        {['Mark As Read', 'Mute', 'Notification Settings'].map((t, i) => (
          <text
            key={t}
            x="164"
            y={72 + i * 22}
            fill="#b5bac1"
            fontSize="12"
            fontFamily="sans-serif"
          >
            {t}
          </text>
        ))}
        <rect x="156" y="130" width="184" height="24" rx="4" fill="#5865f2" />
        <text x="164" y="147" fill="#fff" fontSize="12" fontWeight="bold" fontFamily="sans-serif">
          {item}
        </text>
        <circle cx="330" cy="142" r="9" fill="#fff" />
        <text x="326" y="146" fill="#5865f2" fontSize="11" fontFamily="sans-serif">
          2
        </text>
      </svg>
    </details>
  );
}
