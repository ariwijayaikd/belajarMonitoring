import os
import yaml
import subprocess
from pathlib import Path
from datetime import datetime, timedelta
from typing import List, Optional, Dict

from fastapi import FastAPI, Request, Form, Depends, HTTPException, status
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from jose import JWTError, jwt
from passlib.context import CryptContext
from pydantic import BaseModel

# =========================
# CONFIG
# =========================

SECRET_KEY = os.getenv("SECRET_KEY", "change-this-secret")
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 120

DATA_DIR = Path("/data")
INV_FILE = DATA_DIR / "inventory.yml"

GENERATE_SCRIPT = "/app/generate-targets.py"
PROM_RELOAD_URL = "http://prometheus:9090/-/reload"

# =========================
# FASTAPI INIT
# =========================

app = FastAPI()
templates = Jinja2Templates(directory="templates")
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/token")

# =========================
# FAKE USER STORE (replace with DB later)
# =========================

fake_users = {
    "admin": {
        "username": "admin",
        "hashed_password": pwd_context.hash("admin123"),
        "role": "admin"
    },
    "operator": {
        "username": "operator",
        "hashed_password": pwd_context.hash("operator123"),
        "role": "operator"
    }
}

# =========================
# SCHEMA VALIDATION
# =========================

class Meta(BaseModel):
    app: str
    service_tier: str
    owner_org: str
    env: str
    site: str

class Ports(BaseModel):
    node_exporter: int
    cadvisor: int

class VM(BaseModel):
    name: str
    ip: str
    role: Optional[str] = "service"
    meta: Meta
    ports: Ports
    blackbox: Optional[Dict] = {}

class Inventory(BaseModel):
    vms: List[VM]

# =========================
# AUTH FUNCTIONS
# =========================

def authenticate_user(username: str, password: str):
    user = fake_users.get(username)
    if not user:
        return False
    if not pwd_context.verify(password, user["hashed_password"]):
        return False
    return user

def create_access_token(data: dict):
    expire = datetime.utcnow() + timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES)
    to_encode = data.copy()
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)

@app.post("/token")
def login(form_data: OAuth2PasswordRequestForm = Depends()):
    user = authenticate_user(form_data.username, form_data.password)
    if not user:
        raise HTTPException(status_code=400, detail="Invalid credentials")
    token = create_access_token({"sub": user["username"]})
    return {"access_token": token, "token_type": "bearer"}

def get_current_user(token: str = Depends(oauth2_scheme)):
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        username = payload.get("sub")
        user = fake_users.get(username)
        if not user:
            raise HTTPException(status_code=401)
        return user
    except JWTError:
        raise HTTPException(status_code=401)

def require_admin(user=Depends(get_current_user)):
    if user["role"] != "admin":
        raise HTTPException(status_code=403, detail="Admin only")
    return user

# =========================
# INVENTORY FUNCTIONS
# =========================

def load_inventory():
    if not INV_FILE.exists():
        return {"vms": []}
    return yaml.safe_load(INV_FILE.read_text()) or {"vms": []}

def save_inventory(data):
    INV_FILE.write_text(yaml.dump(data, sort_keys=False))

def git_commit(message):
    subprocess.run(["git", "add", "inventory.yml"], cwd="/data")
    subprocess.run(["git", "commit", "-m", message], cwd="/data")

def regenerate_targets():
    subprocess.run(["python", GENERATE_SCRIPT])
    subprocess.run(["curl", "-X", "POST", PROM_RELOAD_URL])

# =========================
# WEB ROUTES
# =========================

@app.get("/", response_class=HTMLResponse)
def home(request: Request):
    inventory = load_inventory()
    return templates.TemplateResponse(
        "index.html",
        {"request": request, "inventory": inventory}
    )

@app.post("/add")
def add_vm(
    name: str = Form(...),
    ip: str = Form(...),
    app_name: str = Form(...),
    tier: str = Form(...),
    owner: str = Form(...),
    env: str = Form(...),
    site: str = Form(...),
    user=Depends(require_admin)
):
    inv = load_inventory()

    vm = {
        "name": name,
        "ip": ip,
        "meta": {
            "app": app_name,
            "service_tier": tier,
            "owner_org": owner,
            "env": env,
            "site": site
        },
        "ports": {
            "node_exporter": 9100,
            "cadvisor": 8080
        }
    }

    inv["vms"].append(vm)

    Inventory(**inv)  # Validate schema

    save_inventory(inv)
    git_commit(f"Add VM {name}")
    regenerate_targets()

    return RedirectResponse("/", status_code=302)

@app.post("/delete/{vm_name}")
def delete_vm(vm_name: str, user=Depends(require_admin)):
    inv = load_inventory()
    inv["vms"] = [v for v in inv["vms"] if v["name"] != vm_name]
    save_inventory(inv)
    git_commit(f"Delete VM {vm_name}")
    regenerate_targets()
    return RedirectResponse("/", status_code=302)

@app.get("/audit")
def audit(user=Depends(require_admin)):
    result = subprocess.run(
        ["git", "log", "--pretty=format:%h - %s"],
        cwd="/data",
        capture_output=True,
        text=True
    )
    return {"history": result.stdout.split("\n")}

@app.post("/rollback/{commit_hash}")
def rollback(commit_hash: str, user=Depends(require_admin)):
    subprocess.run(["git", "checkout", commit_hash, "inventory.yml"], cwd="/data")
    regenerate_targets()
    return RedirectResponse("/", status_code=302)