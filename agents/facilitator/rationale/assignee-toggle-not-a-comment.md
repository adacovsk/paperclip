# Why a wake is re-fired by toggling the assignee, not by commenting

**Justifies:** *Remedy — re-fire the wake by *changing the assignee*, not by commenting.*

`wakeOnDemand` triggers on an assignee **change**. Re-assigning the *same* agent writes the same value, so no change event fires and nothing wakes — the PATCH returns `200 OK` and looks like it worked.

A re-dispatch *comment* does nothing at all. That is the comment-without-PATCH failure mode applied to wakes, and it is the historical trap here: the comment reads as an action taken, the task looks attended to, and no run ever starts.
