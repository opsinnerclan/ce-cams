# CE Cams - Getting started

CE Cams is a network video recorder you run yourself. Your cameras and recordings stay on your
own machine; nothing is in the cloud. A free cloud (run by CE Cams) is available if you want to
reach your cameras from outside your home without opening ports on your router.

## 1. Install the server

Pick the one that matches where you want to run it:

- **Windows:** download `ce-cams-server-setup.exe` from the releases page and run it. It installs
  the server as a background service that starts with Windows.
  *Windows may show a blue "Windows protected your PC" box the first time - click **More info ->
  Run anyway**. The installer isn't code-signed, which is normal for a small project.*
- **Linux (Debian/Ubuntu):** `sudo apt install ./ce-cams-server_<version>_amd64.deb`. It runs as
  the `ce-cams-server` service.
- **Docker / TrueNAS / Dockge:** download the image tarball, `docker load -i
  ce-cams-server-<version>.tar`, and deploy the included `compose.yaml` (point the two folders at
  where you want settings and recordings to live).

Recordings can get large - put them on a drive with room to spare.

## 2. Connect with the client

1. Install the **CE Cams client** (desktop app) on a PC on the same network.
2. Open it. Your new server appears on the welcome screen. Click it.
3. Set up the server: give it a name and set the **admin** password. You're in.

## 3. Add your cameras

In the client, go to the server and add your cameras (ONVIF/RTSP IP cameras are found
automatically on the network; you can also add one by URL). You can **view cameras live with no
license** - there's no limit on how many you add or watch.

## 4. Turn on recording (needs a license)

Live view is free; **recording** needs a license, one channel per camera you want to record.

- **Trial:** go to **System Administration -> Licenses** and click **Activate Trial License**.
  That gives you 4 cameras of recording for 30 days, once per server, automatically.
- **Permanent license:** ask CE Cams for a key (see below). Then **System Administration ->
  Licenses -> Internet Activation**, paste the key, and activate. Your server contacts the CE
  Cams cloud once to activate; after that it works on its own.

You don't need a cloud account to activate a license - just make sure your server's cloud is set
to `cloud.opsinnerclan.com` (the installer sets this by default). A key works on one server at a
time; if you move it, remove the license in the client first to free the key.

### Getting a license key

Contact CE Cams and say how many cameras you want to record. You'll get a key to paste in step 4.
Keys are issued by hand, so it isn't instant.

## 5. Remote access without opening ports (optional)

To reach your cameras from outside your home network **without port forwarding**, connect your
server to the CE Cams cloud. This needs a cloud account.

1. In the client, **System Administration -> Cloud -> Connect to cloud**.
2. Sign in, or create an account, at `cloud.opsinnerclan.com`. Click **Connect** and enter your
   local admin password when asked.
3. From then on, on any PC, choose **Log in to cloud** on the welcome screen and your system
   shows up wherever you are.

The cloud only brokers the connection - your video goes as directly as possible between your
phone/PC and your server, not stored anywhere by CE Cams.

---

**CE Cams is not a Network Optix product.** The client is an independent fork of the open-source
nx_open project; its source is at the CE Cams client repository.
