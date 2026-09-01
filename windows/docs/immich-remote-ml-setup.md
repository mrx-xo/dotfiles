# Immich Remote ML Worker Setup (Gaming PC)

## What & Why

Immich is running on the homelab and has ~258k ML jobs queued (Smart Search, Face Detection, Facial Recognition). On the homelab's i7-4770HQ (CPU-only), this will take days. The gaming PC has an RTX 5080 that can blast through it in hours.

Immich lets you run the machine learning container on a separate machine. We'll spin it up on the gaming PC with CUDA, point Immich at it, let it clear the queue, then shut it down.

## Prerequisites

- Docker Desktop installed and running (WSL 2 backend enabled)
- NVIDIA drivers up to date (should be if you're gaming on it)
- Gaming PC and homelab on the same LAN

## Step 1: Fix Docker credential issue

```powershell
docker logout
```

## Step 2: Test GPU access in Docker

```powershell
docker run --rm --gpus all nvidia/cuda:12.3.2-base-ubuntu22.04 nvidia-smi
```

You should see your RTX 5080 listed. If this fails, open Docker Desktop settings and make sure GPU support / WSL 2 integration is enabled.

## Step 3: Create the compose file

Create a folder somewhere (e.g. `C:\immich-ml\`) and create a `docker-compose.yml` inside it with this content:

```yaml
name: immich_remote_ml
services:
  immich-machine-learning:
    container_name: immich_machine_learning
    image: ghcr.io/immich-app/immich-machine-learning:release-cuda
    volumes:
      - model-cache:/cache
    restart: always
    ports:
      - 3003:3003
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities:
                - gpu
volumes:
  model-cache:
```

## Step 4: Start the container

```powershell
cd C:\immich-ml
docker compose up -d
```

Wait for the image to pull (it's a few GB). Verify it's running:

```powershell
docker ps
```

You should see `immich_machine_learning` running on port 3003.

## Step 5: Point Immich at the gaming PC

1. Open Immich on homelab: http://192.168.1.143:2283
2. Go to **Administration** (top right) -> **Settings** -> **Machine Learning Settings**
3. Click **Add URL**
4. Enter: `http://192.168.1.159:3003`
5. Keep the existing local URL as a fallback
6. Save

## Step 6: Verify it's working

Go to **Administration** -> **Job Queues**. The waiting counts should start dropping noticeably faster. You can also check GPU usage on the gaming PC:

```powershell
nvidia-smi
```

You should see the `immich_machine_learning` process using GPU memory.

## Step 7: When it's done

Once all queues hit 0 waiting, shut down the container on the gaming PC:

```powershell
cd C:\immich-ml
docker compose down
```

The homelab will handle new photos on its own going forward (only a few at a time, CPU is fine for that).

## Troubleshooting

- **Docker pull fails with credential error**: Run `docker logout` first
- **GPU not visible in Docker**: Make sure Docker Desktop has WSL 2 backend enabled, and restart Docker Desktop after installing/updating NVIDIA drivers
- **Container starts but Immich doesn't use it**: Double-check the URL in Immich ML settings — must be `http://192.168.1.159:3003` (gaming PC's LAN IP, not localhost)
- **Firewall blocking port 3003**: Open port 3003 in Windows Firewall (Settings -> Windows Security -> Firewall -> Advanced -> Inbound Rules -> New Rule -> Port -> 3003 -> Allow)
