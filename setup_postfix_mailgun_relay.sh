#!/bin/bash

# Postfix Mailgun Relay Configuration Script
# This script configures Postfix to relay all mail through Mailgun SMTP

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Postfix Mailgun Relay Configuration ===${NC}"
echo -e "${YELLOW}This script will configure Postfix to relay all system mail through Mailgun${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}This script must be run as root${NC}" 
   exit 1
fi

# Check if Postfix is installed
if ! command -v postfix &> /dev/null; then
    echo -e "${RED}Postfix is not installed. Please install it first.${NC}"
    exit 1
fi

# Backup existing configuration
echo -e "${YELLOW}Creating backup of existing Postfix configuration...${NC}"
cp /etc/postfix/main.cf /etc/postfix/main.cf.backup.$(date +%Y%m%d-%H%M%S)
echo -e "${GREEN}✓ Backup created${NC}"
echo ""

# Collect credentials
echo -e "${BLUE}Please enter your Mailgun SMTP credentials:${NC}"
echo ""

# Get Mailgun username
while true; do
    read -p "Mailgun SMTP Username (e.g., postmaster@mg.yourdomain.com): " MAILGUN_USER
    if [[ -z "$MAILGUN_USER" ]]; then
        echo -e "${RED}Username cannot be empty${NC}"
    elif [[ ! "$MAILGUN_USER" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
        echo -e "${RED}Please enter a valid email format${NC}"
    else
        break
    fi
done

# Get Mailgun password
while true; do
    read -s -p "Mailgun SMTP Password: " MAILGUN_PASS
    echo ""
    if [[ -z "$MAILGUN_PASS" ]]; then
        echo -e "${RED}Password cannot be empty${NC}"
    else
        # Confirm password
        read -s -p "Confirm Mailgun SMTP Password: " MAILGUN_PASS_CONFIRM
        echo ""
        if [[ "$MAILGUN_PASS" != "$MAILGUN_PASS_CONFIRM" ]]; then
            echo -e "${RED}Passwords do not match. Please try again.${NC}"
        else
            break
        fi
    fi
done

# Get Mailgun region
echo ""
echo -e "${BLUE}Select your Mailgun region:${NC}"
echo "1) US (smtp.mailgun.org)"
echo "2) EU (smtp.eu.mailgun.org)"
read -p "Enter choice (1 or 2) [default: 1]: " REGION_CHOICE

case $REGION_CHOICE in
    2)
        MAILGUN_HOST="smtp.eu.mailgun.org"
        echo -e "${GREEN}Using EU region${NC}"
        ;;
    *)
        MAILGUN_HOST="smtp.mailgun.org"
        echo -e "${GREEN}Using US region${NC}"
        ;;
esac

# Optional: Get default FROM address
echo ""
read -p "Default FROM address (leave empty to use system default): " FROM_ADDRESS

# Show configuration summary
echo ""
echo -e "${BLUE}=== Configuration Summary ===${NC}"
echo -e "SMTP Host: ${GREEN}$MAILGUN_HOST${NC}"
echo -e "SMTP Port: ${GREEN}587${NC}"
echo -e "Username: ${GREEN}$MAILGUN_USER${NC}"
echo -e "Password: ${GREEN}[hidden]${NC}"
if [[ -n "$FROM_ADDRESS" ]]; then
    echo -e "Default FROM: ${GREEN}$FROM_ADDRESS${NC}"
fi
echo ""

read -p "Proceed with configuration? (y/n): " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${YELLOW}Configuration cancelled${NC}"
    exit 1
fi

# Create password file
echo -e "${YELLOW}Creating SMTP authentication file...${NC}"
cat > /etc/postfix/sasl_passwd << EOF
[$MAILGUN_HOST]:587 $MAILGUN_USER:$MAILGUN_PASS
EOF

# Secure the password file
chmod 600 /etc/postfix/sasl_passwd
postmap /etc/postfix/sasl_passwd
echo -e "${GREEN}✓ Authentication file created and secured${NC}"

# Update main.cf
echo -e "${YELLOW}Updating Postfix configuration...${NC}"

# Function to update or add a configuration line
update_config() {
    local key="$1"
    local value="$2"
    # Match with or without spaces around the = sign
    if grep -q "^${key}[[:space:]]*=" /etc/postfix/main.cf; then
        # Replace ANY existing occurrence (with or without spaces)
        sed -i "s|^${key}[[:space:]]*=.*|${key} = ${value}|" /etc/postfix/main.cf
    else
        echo "${key} = ${value}" >> /etc/postfix/main.cf
    fi
}

# Update configuration
update_config "relayhost" "[$MAILGUN_HOST]:587"
update_config "smtp_sasl_auth_enable" "yes"
update_config "smtp_sasl_password_maps" "hash:/etc/postfix/sasl_passwd"
update_config "smtp_sasl_security_options" "noanonymous"
update_config "smtp_tls_security_level" "encrypt"
update_config "smtp_tls_note_starttls_offer" "yes"
update_config "inet_interfaces" "loopback-only"

# Add optional FROM address if provided
if [[ -n "$FROM_ADDRESS" ]]; then
    update_config "sender_canonical_maps" "regexp:/etc/postfix/sender_canonical"
    echo "/^.*\$/ $FROM_ADDRESS" > /etc/postfix/sender_canonical
    postmap /etc/postfix/sender_canonical
    echo -e "${GREEN}✓ Default FROM address configured${NC}"
fi

echo -e "${GREEN}✓ Postfix configuration updated${NC}"

# Reload Postfix
echo -e "${YELLOW}Reloading Postfix...${NC}"
systemctl reload postfix
echo -e "${GREEN}✓ Postfix reloaded${NC}"

# Test configuration
echo ""
echo -e "${BLUE}=== Testing Configuration ===${NC}"
echo "Enter an email address to send a test message"
read -p "Test email address: " TEST_EMAIL

if [[ -n "$TEST_EMAIL" ]]; then
    echo "Sending test email to $TEST_EMAIL..."
    echo "This is a test email from Postfix relaying through Mailgun" | mail -s "Postfix Mailgun Relay Test - $(date)" "$TEST_EMAIL"
    
    # Check queue
    sleep 2
    QUEUE_STATUS=$(postqueue -p 2>/dev/null | tail -1)
    if [[ "$QUEUE_STATUS" == "Mail queue is empty" ]]; then
        echo -e "${GREEN}✓ Test email sent successfully (queue is empty)${NC}"
        echo -e "${YELLOW}Check $TEST_EMAIL for the test message${NC}"
    else
        echo -e "${YELLOW}Email queued. Checking status...${NC}"
        postqueue -p | head -10
        echo ""
        echo -e "${YELLOW}If the email is stuck in queue, check:${NC}"
        echo "  - Your Mailgun credentials are correct"
        echo "  - Your Mailgun domain is verified"
        echo "  - Check logs: sudo tail -f /var/log/mail.log"
    fi
else
    echo -e "${YELLOW}Skipping test email${NC}"
fi

# Create uninstall script
echo ""
echo -e "${YELLOW}Creating uninstall script...${NC}"
cat > /usr/local/bin/mailgun-relay-uninstall << 'UNINSTALL_EOF'
#!/bin/bash
echo "Removing Mailgun relay configuration..."

# Restore backup if exists
LATEST_BACKUP=$(ls -t /etc/postfix/main.cf.backup.* 2>/dev/null | head -1)
if [[ -f "$LATEST_BACKUP" ]]; then
    cp "$LATEST_BACKUP" /etc/postfix/main.cf
    echo "Restored configuration from $LATEST_BACKUP"
else
    # Remove relay configuration lines
    sed -i '/^relayhost.*smtp.mailgun.org/d' /etc/postfix/main.cf
    sed -i '/^smtp_sasl_auth_enable/d' /etc/postfix/main.cf
    sed -i '/^smtp_sasl_password_maps/d' /etc/postfix/main.cf
    sed -i '/^smtp_sasl_security_options/d' /etc/postfix/main.cf
    sed -i '/^smtp_tls_security_level/d' /etc/postfix/main.cf
    sed -i '/^smtp_tls_note_starttls_offer/d' /etc/postfix/main.cf
    sed -i '/^sender_canonical_maps/d' /etc/postfix/main.cf
fi

# Remove password files
rm -f /etc/postfix/sasl_passwd*
rm -f /etc/postfix/sender_canonical*

# Reload Postfix
systemctl reload postfix
echo "Mailgun relay configuration removed"
echo "Postfix is now back to direct delivery"
UNINSTALL_EOF

chmod +x /usr/local/bin/mailgun-relay-uninstall
echo -e "${GREEN}✓ Uninstall script created at /usr/local/bin/mailgun-relay-uninstall${NC}"

# Final summary
echo ""
echo -e "${GREEN}=== Configuration Complete ===${NC}"
echo ""
echo -e "${GREEN}✓${NC} Postfix is now configured to relay all mail through Mailgun"
echo -e "${GREEN}✓${NC} Configuration backup saved with timestamp"
echo -e "${GREEN}✓${NC} Uninstall script available at: ${BLUE}/usr/local/bin/mailgun-relay-uninstall${NC}"
echo ""
echo -e "${YELLOW}Important notes:${NC}"
echo "• All system mail will now be sent through Mailgun"
echo "• WordPress sites using SMTP plugins will bypass this relay"
echo "• Check delivery: ${BLUE}sudo tail -f /var/log/mail.log${NC}"
echo "• View mail queue: ${BLUE}sudo postqueue -p${NC}"
echo "• To remove this configuration: ${BLUE}sudo mailgun-relay-uninstall${NC}"
echo ""
echo -e "${GREEN}Setup complete!${NC}"
