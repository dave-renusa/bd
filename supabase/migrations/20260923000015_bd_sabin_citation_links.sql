-- BD Radar: Sabin citation links.
-- The Sabin loader stored the whole Citations text as the signal URL, so the
-- site linked to a relative path and got a 404. Keep only the first web
-- address (the feed now does the same), or null when the citation has none.
update bd.signals
set url = regexp_replace((regexp_match(url, 'https?://[^\s;,<>"'']+', 'i'))[1], '[.)\]]+$', '')
where source in ('sabin_contested', 'sabin_restriction')
  and url is not null
  and url !~ '^https?://\S+$';
