# Use one synchronized Toast across displays

OpsBeacon permits only one logical Toast at a time and renders one synchronized copy of it on every Active Display; new Alerts append to that shared list, and Acknowledgement from any copy closes them all. This preserves multi-display visibility without allowing independent Toast stacks to accumulate, at the cost of coordinating presentation state and user actions across multiple macOS windows.
