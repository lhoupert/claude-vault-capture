r"""Pattern/replacement definitions for scrub.py.

Each rule is applied as one `pattern.subn(replacement, text)` — the replacement
is a regex template, so what gets written is readable right here in the table.
All patterns are compiled with re.MULTILINE so ^ and $ match every line.
Cross-line patterns use [\s\S] explicitly — not re.DOTALL — so future flag
changes cannot silently regress them.
"""

RULES = [
    {
        "name": "private_key",
        "pattern": r"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----",
        "replacement": "<redacted:private_key>",
    },
    {
        "name": "token_prefix",
        "pattern": (
            r"sk-ant-[A-Za-z0-9_\-]+"
            r"|sk-[A-Za-z0-9]+"
            r"|gh[pousr]_[A-Za-z0-9]+"
            r"|xox[baprs]-[0-9]+-[A-Za-z0-9\-]+"
            r"|AKIA[0-9A-Z]{16}"
            r"|AIza[0-9A-Za-z\-_]{35}"
        ),
        "replacement": "<redacted:token_prefix>",
    },
    {
        "name": "jwt",
        "pattern": r"eyJ[A-Za-z0-9_\-]+\.eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+",
        "replacement": "<redacted:jwt>",
    },
    {
        "name": "env_var",
        # Only the value is replaced; key name and spacing are kept for context
        # (the whole pre-value span is captured and written back verbatim).
        # [^\s#]+ means trailing comments survive intact.
        # ^ anchored per-line via re.MULTILINE.
        "pattern": (
            r"^(?P<pre>[ \t]*(?P<k>[A-Z][A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD|PASS|PWD|CREDENTIAL|API)[A-Z0-9_]*)"
            r"[ \t]*=[ \t]*)(?P<v>[^\s#]+)"
        ),
        "replacement": r"\g<pre><redacted:env_var>",
    },
    {
        "name": "bearer",
        "pattern": r"(?i)(?:authorization[:\s=]+bearer[:\s]+|bearer[:\s]+)[A-Za-z0-9_\-\.=]+",
        "replacement": "<redacted:bearer>",
    },
    {
        "name": "basic_auth_url",
        # User is kept; password (after ':') is replaced.
        "pattern": r"(https?://[^:/\s]+:)[^@/\s]+(@)",
        "replacement": r"\g<1><redacted:basic_auth_url>\g<2>",
    },
]
