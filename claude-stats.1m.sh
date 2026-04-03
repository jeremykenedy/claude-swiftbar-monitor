#!/usr/bin/env bash
# <swiftbar.title>Claude Monitor</swiftbar.title>
# <swiftbar.version>9.0</swiftbar.version>
# <swiftbar.author>swiftbar-plugin</swiftbar.author>
# <swiftbar.desc>Claude real usage stats</swiftbar.desc>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>
# <swiftbar.hideDisablePlugin>true</swiftbar.hideDisablePlugin>

RATE_FILE="$HOME/.claude/rate-limit.json"
CACHE_FILE="$HOME/.claude/usage-cache.json"

if [ "$1" = "log-rate-limit" ]; then
  UNTIL=$(osascript -e 'text returned of (display dialog "Rate limited until? (e.g. 5:00 AM)" default answer "" with title "Claude Rate Limit")')
  [ -z "$UNTIL" ] && exit 0
  printf '{"until":"%s","logged":"%s"}' "$UNTIL" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RATE_FILE"
  exit 0
fi

if [ "$1" = "clear-rate-limit" ]; then
  rm -f "$RATE_FILE"
  exit 0
fi

# Fetch via Chrome -- auto-detects org ID from the page, no hardcoded values
FETCHED=$(osascript <<'APPLESCRIPT' 2>/dev/null
tell application "Google Chrome"
  set theJS to "(function(){try{" & \
    "var orgMatch = document.cookie.match(/[?&]?org[_-]?id=([^;]+)/);" & \
    "var org = '';" & \
    "var scripts = document.querySelectorAll('script');" & \
    "for(var i=0;i<scripts.length;i++){" & \
    "  var m = (scripts[i].textContent||'').match(/organizations\\/([a-f0-9-]{36})/);" & \
    "  if(m){org=m[1];break;}" & \
    "}" & \
    "if(!org){" & \
    "  var m2=window.location.href.match(/organizations\\/([a-f0-9-]{36})/);" & \
    "  if(m2)org=m2[1];" & \
    "}" & \
    "if(!org)return '';" & \
    "return fetch('/api/organizations/'+org+'/usage',{credentials:'include'})" & \
    "  .then(r=>r.text())" & \
    "  .then(t=>{" & \
    "    var e=document.createElement('div');" & \
    "    e.id='_sb';e.style.display='none';e.innerText=t;" & \
    "    document.body.appendChild(e);" & \
    "  });" & \
    "}catch(e){return '';}})();"
  repeat with w in windows
    repeat with t in tabs of w
      if URL of t contains "claude.ai" then
        execute t javascript theJS
        delay 2
        set result to execute t javascript "var el=document.getElementById('_sb');var r=el?el.innerText:'';if(el)el.remove();r;"
        if result is not "" then return result
      end if
    end repeat
  end repeat
  return ""
end tell
APPLESCRIPT
)

if [ -n "$FETCHED" ] && echo "$FETCHED" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
  echo "$FETCHED" > "$CACHE_FILE"
fi

/usr/bin/python3 - "$RATE_FILE" "$CACHE_FILE" <<'PYEOF'
import json, os, sys, datetime

rate_file  = sys.argv[1]
cache_file = sys.argv[2]

rate_until = ""
if os.path.exists(rate_file):
    try:
        with open(rate_file) as f: rl = json.load(f)
        rate_until = rl.get("until","")
    except: pass

usage = {}
if os.path.exists(cache_file):
    try:
        raw = open(cache_file).read().strip()
        if raw: usage = json.loads(raw)
    except: pass

def pct(val):
    try: return int(float(val))
    except: return 0

def bar(p, width=8):
    filled = int(min(p,100)/100*width)
    return "█"*filled + "░"*(width-filled)

def fmt_reset(iso):
    try:
        dt = datetime.datetime.fromisoformat(iso.replace("Z","+00:00"))
        now = datetime.datetime.now(datetime.timezone.utc)
        diff = dt - now
        total = int(diff.total_seconds())
        if total <= 0: return "resetting soon"
        h, m = divmod(total // 60, 60)
        if h >= 24:
            d = h // 24
            return f"{d}d {h%24}h"
        if h > 0: return f"{h}h {m}m"
        return f"{m}m"
    except: return "?"

five_hr = usage.get("five_hour") or {}
seven_d = usage.get("seven_day") or {}
sonnet  = usage.get("seven_day_sonnet") or {}

s_pct  = pct(five_hr.get("utilization", 0))
s_rst  = fmt_reset(five_hr.get("resets_at",""))
wa_pct = pct(seven_d.get("utilization", 0))
wa_rst = fmt_reset(seven_d.get("resets_at",""))
ws_pct = pct(sonnet.get("utilization", 0))
ws_rst = fmt_reset(sonnet.get("resets_at",""))
has_data = bool(five_hr)

if rate_until:
    print(f"🤖 🚫 until {rate_until}")
elif has_data:
    print(f"🤖 S:{s_pct}% W:{wa_pct}%")
else:
    print("🤖 (open claude.ai in Chrome)")

print("---")

if rate_until:
    print(f"🚫 Locked until {rate_until} | color=red")
    print(f"--Clear | bash=$0 param1=clear-rate-limit terminal=false refresh=true")
    print("---")

if has_data:
    print(f"Session (5hr):   {bar(s_pct)} {s_pct}% | color=#0066CC")
    print(f"  Resets in {s_rst} | color=#00CC66")
    print("---")
    print(f"Weekly (all):    {bar(wa_pct)} {wa_pct}% | color=#0066CC")
    print(f"  Resets in {wa_rst} | color=#00CC66")
    print("---")
    print(f"Weekly (Sonnet): {bar(ws_pct)} {ws_pct}% | color=#0066CC")
    print(f"  Resets in {ws_rst} | color=#00CC66")
else:
    print("No data — open claude.ai in Chrome")

print("---")
print(f"🕐 Updated {datetime.datetime.now().strftime('%-I:%M:%S %p')} | color=#00CC66")
print("---")
print("🚫 Log rate limit... | bash=$0 param1=log-rate-limit terminal=false refresh=true")
print("Refresh | refresh=true")
PYEOF
