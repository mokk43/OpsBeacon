# Cap displayed and Pending Alert rows at 200

The one Toast retains at most the newest 200 displayed Alert rows, and an active Collection Window separately retains at most the newest 200 Pending Alerts; each state durably counts omitted earlier matches, and delivery transfers the Pending omissions into the Toast's displayed overflow count. This deliberately sacrifices complete unacknowledged message retention to bound memory, disk, and rendering work during event floods while keeping the most recent operational state visible.
