import { useEffect } from 'react';
import { useInstructors, useTeam } from './data';
import { clearDiscordNames, setDiscordNames } from './discordNames';

/** Loads the names once for the whole app (mounted in the app shell). */
export function useDiscordNames() {
  const team = useTeam();
  const instructors = useInstructors();
  useEffect(() => {
    clearDiscordNames();
    setDiscordNames((team.data ?? []).map((t) => [t.discord_user_id, t.name]));
    setDiscordNames((instructors.data ?? []).map((i) => [i.discord_user_id, i.full_name]));
  }, [team.data, instructors.data]);
}
