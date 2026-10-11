"""
Meridian OIDC sample app (v1.2)

One codebase, deployed twice (SWIFT Wire Release Console, Actimize AML Case Manager).
Each deployment is configured entirely through environment variables.

What it does:
  - Signs users in through Keycloak (authorization code flow + PKCE S256)
  - Reads the flat `roles` claim that Keycloak puts in this app's tokens
  - Allows or denies each action by the role it requires
  - Forces step-up MFA (acr_values=gold) for actions that require it, valid for 5 minutes
  - Revalidates the session with Keycloak (refresh token grant) before every action,
    so a revoked session or disabled user is thrown out on their next click
  - Writes every decision as a JSON line (audit evidence)
"""
import base64, json, logging, os, time
from urllib.parse import urlencode
import requests
from flask import Flask, redirect, url_for, session, abort, render_template_string, request
from authlib.integrations.flask_client import OAuth

logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("authz")

APP_NAME = os.environ["APP_NAME"]
BASE_URL = os.environ["BASE_URL"].rstrip("/")
ISSUER = os.environ["OIDC_ISSUER"]
CLIENT_ID = os.environ["CLIENT_ID"]
CLIENT_SECRET = os.environ["CLIENT_SECRET"]
ACTIONS = json.loads(os.environ["APP_ACTIONS"])
STEPUP_MAX_AGE = int(os.environ.get("STEPUP_MAX_AGE", "300"))

app = Flask(__name__)
app.secret_key = os.environ["SESSION_SECRET"]
app.config.update(SESSION_COOKIE_SECURE=True, SESSION_COOKIE_HTTPONLY=True, SESSION_COOKIE_SAMESITE="Lax")

oauth = OAuth(app)
oauth.register(
    "keycloak",
    client_id=CLIENT_ID,
    client_secret=CLIENT_SECRET,
    server_metadata_url=f"{ISSUER}/.well-known/openid-configuration",
    client_kwargs={"scope": "openid profile email", "code_challenge_method": "S256"},
)

PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>{{ app_name }}</title>
<style>body{font-family:Segoe UI,Arial,sans-serif;max-width:720px;margin:40px auto;padding:0 16px}
.ok{background:#e6f4ea;border:1px solid #34a853;padding:12px;margin:12px 0}
.deny{background:#fce8e6;border:1px solid #d93025;padding:12px;margin:12px 0}
code{background:#f1f3f4;padding:2px 4px}
a.btn{display:inline-block;margin:4px 8px 4px 0;padding:8px 12px;border:1px solid #444;text-decoration:none;color:#000}</style>
</head><body><h1>{{ app_name }}</h1>
{% if message and not user %}<div class="deny">{{ message }}</div>{% endif %}
{% if not user %}<p>Not signed in.</p><a class="btn" href="/login">Sign in with Meridian SSO</a>
{% else %}<p>Signed in as <b>{{ user.username }}</b> ({{ user.name }})</p>
<p>Roles in token for this app: <code>{{ user.roles or "none" }}</code> &nbsp; Auth level (acr): <code>{{ user.acr }}</code></p>
{% if message %}<div class="{{ 'ok' if allowed else 'deny' }}">{{ message }}</div>{% endif %}
<h3>Actions</h3>
{% for key, a in actions.items() %}<a class="btn" href="/action/{{ key }}">{{ a.label }}</a> requires <code>{{ a.role }}</code>{% if a.acr %} + MFA (<code>{{ a.acr }}</code>){% endif %}<br>{% endfor %}
<p><a href="/logout">Sign out</a></p>{% endif %}</body></html>"""


def render(**kw):
    return render_template_string(PAGE, app_name=APP_NAME, user=session.get("user"), actions=ACTIONS, **kw)


def audit(**kw):
    log.info(json.dumps({"app": APP_NAME, **kw}))


def jwt_claims(tok):
    p = tok.split(".")[1]
    p += "=" * (-len(p) % 4)
    return json.loads(base64.urlsafe_b64decode(p))


def revalidate(user):
    """Ask Keycloak for a fresh token. Fails if the session was revoked or the user disabled."""
    rt = session.get("refresh_token")
    if not rt:
        audit(event="session_revoked", user=user["username"], reason="no refresh token")
        return False
    endpoint = oauth.keycloak.load_server_metadata()["token_endpoint"]
    r = requests.post(endpoint, data={"grant_type": "refresh_token", "refresh_token": rt},
                      auth=(CLIENT_ID, CLIENT_SECRET), timeout=10)
    if r.status_code != 200:
        body = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
        audit(event="session_revoked", user=user["username"],
              reason=body.get("error_description", f"HTTP {r.status_code}"))
        return False
    new = r.json()
    old_roles = user["roles"]
    user["roles"] = jwt_claims(new["access_token"]).get("roles", [])
    if sorted(old_roles) != sorted(user["roles"]):
        audit(event="roles_changed", user=user["username"], before=old_roles, after=user["roles"])
    session["user"] = user
    session["refresh_token"] = new.get("refresh_token", rt)
    return True


@app.route("/")
def home():
    return render(message=None, allowed=None)


@app.route("/login")
def login():
    acr = request.args.get("acr")
    extra = {"acr_values": acr} if acr else {}
    session["requested_acr"] = acr
    return oauth.keycloak.authorize_redirect(f"{BASE_URL}/callback", **extra)


@app.route("/callback")
def callback():
    token = oauth.keycloak.authorize_access_token()
    c = token["userinfo"]
    session["user"] = {"username": c.get("preferred_username"), "name": c.get("name"),
                       "roles": c.get("roles", []), "acr": c.get("acr")}
    session["refresh_token"] = token.get("refresh_token")
    requested = session.pop("requested_acr", None)
    if requested and c.get("acr") == requested:
        session["stepup_at"] = time.time()
        audit(event="stepup", user=c.get("preferred_username"), acr=c.get("acr"))
    else:
        audit(event="login", user=c.get("preferred_username"), roles=c.get("roles", []), acr=c.get("acr"))
    nxt = session.pop("next_action", None)
    return redirect(url_for("action", name=nxt) if nxt else url_for("home"))


@app.route("/action/<name>")
def action(name):
    user = session.get("user")
    if not user:
        return redirect(url_for("login"))
    if name not in ACTIONS:
        abort(404)
    if not revalidate(user):
        session.clear()
        return render(message="Your session is no longer valid. Access has been revoked.", allowed=False), 401
    a = ACTIONS[name]
    if a["role"] not in user["roles"]:
        audit(event="authz", user=user["username"], action=name, required_role=a["role"],
              user_roles=user["roles"], decision="DENY", reason="missing role")
        return render(message=f"DENIED: {a['label']} requires role '{a['role']}'.", allowed=False), 403
    need_acr = a.get("acr")
    if need_acr:
        fresh = user.get("acr") == need_acr and time.time() - session.get("stepup_at", 0) <= STEPUP_MAX_AGE
        if not fresh:
            audit(event="stepup_required", user=user["username"], action=name,
                  required_acr=need_acr, current_acr=user.get("acr"))
            session["next_action"] = name
            return redirect(url_for("login", acr=need_acr))
    audit(event="authz", user=user["username"], action=name, required_role=a["role"],
          user_roles=user["roles"], acr=user.get("acr"), decision="ALLOW")
    return render(message=f"ALLOWED: {a['label']}.", allowed=True)


@app.route("/logout")
def logout():
    session.clear()
    end = oauth.keycloak.load_server_metadata()["end_session_endpoint"]
    return redirect(end + "?" + urlencode({"client_id": CLIENT_ID, "post_logout_redirect_uri": BASE_URL + "/"}))
