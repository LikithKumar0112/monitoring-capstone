# AWS EC2 Setup Guide

This guide gets you from "no server" to "ready to `docker compose up`" for every project in this repo.
You only do the provisioning **once**; then you run one project stack at a time on the same instance.

---

## 1. Launch the EC2 instance

In the AWS Console → **EC2 → Launch instance**:

| Setting | Value | Notes |
|---------|-------|-------|
| **Name** | `monitoring-capstone` | |
| **AMI** | Ubuntu Server 22.04 LTS *(or Amazon Linux 2023)* | Guide uses Ubuntu commands; AL2023 notes below |
| **Instance type** | **m7i-flex.large** (2 vCPU / 8 GB) — *or* t3.large (8 GB) / t3.xlarge (16 GB) | Need **≥ 8 GB RAM**; ELK (5.2) and Thanos (5.4) OOM below that. Avoid t3.micro (1 GB), t3.small (2 GB), c7i-flex.large (4 GB) |
| **Key pair** | Create/select one (`.pem`) | Needed for SSH |
| **Storage** | **30 GB gp3** | Docker images + indices add up |
| **Security group** | See section 2 | |

> **Cost tip:** these are on-demand instances that bill per second while *running*. **Stop** the
> instance when you take a break, and **terminate** it when the capstone is finished. Stopped
> instances only bill for the EBS volume.

### Amazon Linux 2023 differences
- Package manager is `dnf`, not `apt`.
- Default SSH user is `ec2-user` (Ubuntu uses `ubuntu`).
- Install Docker with `sudo dnf install -y docker` then `sudo systemctl enable --now docker`.

---

## 2. Security group (firewall)

Create inbound rules. **Set the Source of every rule to `My IP`** — never `0.0.0.0/0` for these
dashboards; they have weak/default auth and should not be exposed to the whole internet.

| Port | Service | Used in |
|------|---------|---------|
| 22 | SSH | all |
| 3000 | Grafana | 5.1, 5.4 |
| 9090 | Prometheus UI | 5.1, 5.3, 5.4 |
| 9093 | Alertmanager | 5.3 |
| 9100 | Node Exporter | 5.1 |
| 8080 | cAdvisor / HotROD UI | 5.1, 5.3 |
| 5601 | Kibana | 5.2 |
| 9200 | Elasticsearch | 5.2 |
| 16686 | Jaeger UI | 5.3 |
| 9000 / 9001 | MinIO API / Console | 5.4 |
| 10902 | Thanos Query UI | 5.4 |

You can open them all now, or add each as you reach the project that needs it.

---

## 3. Connect and install Docker

SSH in (replace with your key and the instance's public IP/DNS):

```bash
ssh -i monitoring-capstone.pem ubuntu@<EC2_PUBLIC_IP>
```

Install Docker Engine + the Compose plugin (Ubuntu):

```bash
# Update and install prerequisites
sudo apt-get update
sudo apt-get install -y ca-certificates curl git

# Add Docker's official repository
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install engine + compose plugin
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Run docker without sudo (log out/in afterwards for it to take effect)
sudo usermod -aG docker $USER
newgrp docker

# Verify
docker version
docker compose version
```

---

## 4. Kernel setting required for Elasticsearch (Project 5.2)

Elasticsearch refuses to start unless `vm.max_map_count` is high enough. Set it now (persists across
reboots):

```bash
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-elasticsearch.conf
sudo sysctl --system
# confirm
sysctl vm.max_map_count      # should print 262144
```

---

## 5. Get the code and run a project

```bash
git clone <YOUR_REPO_URL> monitoring        # or scp/rsync the folder up
cd monitoring/project-5.1-prometheus-grafana
cp ../.env.example .env                       # then edit passwords with: nano .env
docker compose up -d
docker compose ps                             # wait for state = running/healthy
docker compose logs -f prometheus             # tail logs if something looks off
```

Open a browser to `http://<EC2_PUBLIC_IP>:<PORT>` (ports per project README).

When finished with a project, free the RAM before the next one:

```bash
docker compose down -v
```

---

## 6. Housekeeping

- **RAM check:** `free -h` — if a stack is being OOM-killed, stop other stacks or size up the instance.
- **Disk check:** `df -h` and `docker system df`. Reclaim space with `docker system prune -af --volumes`
  (this deletes stopped containers/volumes — only run between projects).
- **Reboots:** stacks come back with `docker compose up -d` again; data in named volumes persists unless
  you used `down -v`.
- **Stop billing:** EC2 Console → select instance → **Instance state → Stop** (or **Terminate** to delete).
