import smtplib
import socket
import os
import sys
import logging
from email.message import EmailMessage
from datetime import datetime

# ─── Logging Setup ────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.DEBUG,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("ops/send_report.log", mode="a"),
    ],
)
log = logging.getLogger(__name__)

# ─── Configuration ────────────────────────────────────────────────────────────
SMTP_SERVER     = os.getenv("SMTP_SERVER", "smtp.gmail.com")
SMTP_PORT       = int(os.getenv("SMTP_PORT", 465))
EMAIL_USER      = os.getenv("EMAIL_USER")
EMAIL_PASS      = os.getenv("EMAIL_PASS")
RECIPIENT_EMAIL = os.getenv("RECIPIENT_EMAIL")
# Dynamic Platform detection
TEST_PLATFORM   = os.getenv("TEST_PLATFORM", "android").lower() # defaults to android if not set

# Logic to handle different folder structures
# Looks in: android/html-reports/... OR ios/html-reports/...
BASE_REPORT_DIR = f"{TEST_PLATFORM}/html-reports"

REPORT_FILES    = [
    os.path.join(BASE_REPORT_DIR, "dynamic-test-report.html"),
    os.path.join(BASE_REPORT_DIR, "dynamic-test-report.pdf"),
]

# ─── Validation ───────────────────────────────────────────────────────────────
def validate_config():
    log.info("━━━ Validating configuration ━━━")
    errors = []
    if not EMAIL_USER:
        errors.append("EMAIL_USER is not set")
    if not EMAIL_PASS:
        errors.append("EMAIL_PASS is not set")
    if not RECIPIENT_EMAIL:
        errors.append("RECIPIENT_EMAIL is not set")

    log.info(f"  SMTP_SERVER     : {SMTP_SERVER}")
    log.info(f"  SMTP_PORT       : {SMTP_PORT}")
    log.info(f"  EMAIL_USER      : {EMAIL_USER or '(NOT SET)'}")
    log.info(f"  EMAIL_PASS      : {'(SET)' if EMAIL_PASS else '(NOT SET)'}")
    log.info(f"  RECIPIENT_EMAIL : {RECIPIENT_EMAIL or '(NOT SET)'}")

    if errors:
        for e in errors:
            log.error(f"  ✗ {e}")
        sys.exit(1)
    log.info("  ✓ All required env vars are set")

# ─── Network Pre-check ────────────────────────────────────────────────────────
def check_network():
    log.info("━━━ Network reachability check ━━━")
    try:
        socket.setdefaulttimeout(5)
        socket.create_connection((SMTP_SERVER, SMTP_PORT))
        log.info(f"  ✓ {SMTP_SERVER}:{SMTP_PORT} is reachable")
        return True
    except socket.timeout:
        log.error(f"  ✗ Connection to {SMTP_SERVER}:{SMTP_PORT} timed out")
        log.error("    → Port may be firewalled on this machine")
    except OSError as e:
        log.error(f"  ✗ Cannot reach {SMTP_SERVER}:{SMTP_PORT} — {e}")
        log.error("    → Check: firewall rules, ISP/cloud provider SMTP blocking")
        log.error("    → Try:   nc -zv smtp.gmail.com 465")
        log.error("    → Try:   sudo ufw allow out 465/tcp")
    return False

# ─── Build Email ──────────────────────────────────────────────────────────────
def build_message():
    log.info("━━━ Building email message ━━━")
    msg = EmailMessage()
    msg["Subject"] = f"Propwire Mobile Test Report — {datetime.now().strftime('%Y-%m-%d %H:%M')}"
    msg["From"]    = EMAIL_USER
    msg["To"]      = RECIPIENT_EMAIL
    msg.set_content("Please find the attached E2E Test Reports (HTML & PDF).")

    attached = []
    missing  = []
    for file_path in REPORT_FILES:
        if os.path.exists(file_path):
            size = os.path.getsize(file_path)
            with open(file_path, "rb") as f:
                file_data = f.read()
            file_name = os.path.basename(file_path)
            msg.add_attachment(
                file_data,
                maintype="application",
                subtype="octet-stream",
                filename=file_name,
            )
            log.info(f"  ✓ Attached: {file_path} ({size / 1024:.1f} KB)")
            attached.append(file_path)
        else:
            log.warning(f"  ✗ File not found, skipping: {file_path}")
            missing.append(file_path)

    if not attached:
        log.error("  No report files found — nothing to attach. Aborting.")
        sys.exit(1)

    if missing:
        log.warning(f"  {len(missing)} file(s) missing and will not be attached")

    return msg

# ─── Send Mail ────────────────────────────────────────────────────────────────
def send_mail(msg):
    log.info("━━━ Connecting to SMTP server ━━━")

    # Port 465 → SMTP_SSL (SSL from the start)
    # Port 587 → SMTP + STARTTLS
    use_ssl = (SMTP_PORT == 465)
    log.info(f"  Mode: {'SMTP_SSL (port 465)' if use_ssl else 'STARTTLS (port 587)'}")

    try:
        if use_ssl:
            log.debug(f"  Opening SMTP_SSL connection to {SMTP_SERVER}:{SMTP_PORT}")
            context = __import__("ssl").create_default_context()
            server_cls = smtplib.SMTP_SSL(SMTP_SERVER, SMTP_PORT, context=context, timeout=15)
        else:
            log.debug(f"  Opening SMTP connection to {SMTP_SERVER}:{SMTP_PORT}")
            server_cls = smtplib.SMTP(SMTP_SERVER, SMTP_PORT, timeout=15)

        with server_cls as server:
            if not use_ssl:
                log.debug("  Upgrading connection with STARTTLS...")
                server.starttls()

            log.debug("  Sending EHLO...")
            server.ehlo()

            log.info(f"  Logging in as {EMAIL_USER}...")
            server.login(EMAIL_USER, EMAIL_PASS)
            log.info("  ✓ Login successful")

            log.info(f"  Sending email to {RECIPIENT_EMAIL}...")
            server.send_message(msg)
            log.info("  ✓ Email sent successfully!")

    except smtplib.SMTPAuthenticationError as e:
        log.error(f"  ✗ Authentication failed: {e}")
        log.error("    → Gmail: ensure you are using an App Password, not your account password")
        log.error("    → Gmail App Password: myaccount.google.com/apppasswords")
        sys.exit(1)
    except smtplib.SMTPServerDisconnected as e:
        log.error(f"  ✗ Server disconnected unexpectedly: {e}")
        log.error(f"    → You are on port {SMTP_PORT} but may be using the wrong connection mode")
        log.error("    → Port 465 requires SMTP_SSL, port 587 requires STARTTLS")
        sys.exit(1)
    except smtplib.SMTPException as e:
        log.error(f"  ✗ SMTP error: {e}")
        sys.exit(1)
    except socket.timeout:
        log.error(f"  ✗ Connection timed out after 15s")
        sys.exit(1)
    except OSError as e:
        log.error(f"  ✗ Network error: {e}")
        sys.exit(1)

# ─── Entry Point ──────────────────────────────────────────────────────────────
if __name__ == "__main__":
    log.info("═══════════════════════════════════════")
    log.info("  Propwire E2E — Send Report Script")
    log.info("═══════════════════════════════════════")

    validate_config()

    if not check_network():
        log.error("Network check failed. Skipping email send.")
        log.error("Fix network/firewall issue then retry.")
        sys.exit(1)

    msg = build_message()
    send_mail(msg)