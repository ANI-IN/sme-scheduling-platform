-- Release Milestone 5: clearer names for the two "close to the class" settings (display text only).
update public.setting_definition set
  label = 'Close to the class (days before)',
  help = 'Inside this many days, problems are urgent and the middle reply time is used.'
 where key = 'short_notice_days';
update public.setting_definition set
  label = 'Very close to the class (days before)',
  help = 'Inside this many days, replies are expected fastest and the shorter quiet hours for urgent messages apply.'
 where key = 'urgent_band_days';
update public.setting_definition set help = 'One task per line. Added to every class when an instructor confirms.'
 where key = 'checklist_items';
