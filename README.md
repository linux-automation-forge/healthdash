One bash script → a live terminal dashboard for your own machine: CPU, RAM,swap, disks, per-interface network rates, top processes, and a quick securityline (failed logins + listening ports). Press q to quit. -1 renders a singleframe (perfect for cron or screenshots).

quick start
git clone https://github.com/YOURNAME/healthdash.gitcd healthdashchmod +x healthdash.sh./healthdash.sh
why I built it
htop is great, but I wanted ONE screen answering MY questions: am I about torun out of disk, what is eating CPU right now, is anything hammering my ssh?

notes
Linux + WSL2. bash 4+. Read-only — never changes anything on your system.
Failed-login panel uses lastb/auth.log when readable; shows n/a otherwise(normal on WSL).
Colors auto-disable when piped (cron-friendly). NO_COLOR is respected.
Self-test: HEALTHDASH_SELFTEST=1 bash healthdash.sh
Thresholds, interval, top-N: edit the DEFAULTS block at the top of thescript, or pass flags (-i 1, -t 10).
MIT licensed. No warranty.
