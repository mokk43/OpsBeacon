# Use ordered first-match Rule evaluation

Each Source owns an explicitly user-ordered list of Rules that is evaluated from top to bottom, skipping disabled Rules and stopping at the first match, so a Signal creates at most one Alert. This avoids duplicate Alerts when conditions overlap, at the cost of making order semantically significant; Settings must therefore expose the order directly and allow users to change it rather than relying on hidden priorities.
