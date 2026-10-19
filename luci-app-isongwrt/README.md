
### Rule-set prefetch (optional, default off)

`isongwrt.main.prefetch=1` enables a reachability probe of all remote rule sets before service
operations. The probe uses HEAD/Range requests only: it does **not** write `cache.db` and is **not**
a cache warm-up. A failed probe aborts a `restart` **only while a core is actually running**; a
restart from the stopped state and `start` continue with a warning. Use `--skip-prefetch` to bypass.
