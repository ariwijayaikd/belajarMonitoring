from pydantic import BaseModel, HttpUrl
from typing import List, Optional, Dict

class BlackboxHTTP(BaseModel):
    url: HttpUrl
    labels: Optional[Dict[str, str]] = {}

class BlackboxTCP(BaseModel):
    target: str
    labels: Optional[Dict[str, str]] = {}

class Ports(BaseModel):
    node_exporter: int
    cadvisor: int

class Meta(BaseModel):
    app: str
    service_tier: str  # fe/be/db/lb
    owner_org: str
    env: str
    site: str

class VM(BaseModel):
    name: str
    ip: str
    role: Optional[str] = "service"
    meta: Meta
    ports: Ports
    blackbox: Optional[Dict[str, List]] = {}

class Inventory(BaseModel):
    vms: List[VM]