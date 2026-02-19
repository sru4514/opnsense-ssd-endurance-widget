@ -0,0 +1,93 @@
Install with the installation script.

Then hard-refresh your browser (Command+Shift+R) and go to:
Dashboard → Add widget

SSD Endurance

SSD Endurance Gauge

Files installed

JS widgets:

/usr/local/opnsense/www/js/widgets/SmartEndurance.js

/usr/local/opnsense/www/js/widgets/SmartEnduranceGauge.js

Metadata:

/usr/local/opnsense/www/js/widgets/Metadata/SmartEndurance.xml

/usr/local/opnsense/www/js/widgets/Metadata/SmartEnduranceGauge.xml

Backups (to survive upgrades):

/conf/custom_widgets/js/*.js

/conf/custom_widgets/Metadata/*.xml

Configuration
Rated TBW (endurance)

The widgets use:

a best-effort SMART auto-detect (often unavailable),

otherwise a configured fallback TBW:

Edit in the JS files:

this.RATED_TBW = 500;

Example values vary by drive model and capacity.

Table widget Mode default

The table widget remembers the mode per browser using localStorage:

default is Compact

click Mode to switch to Detailed

persists across refreshes in the same browser

Updating

Re-run the installer:

sudo sh /root/install-smartendurance.sh

Uninstall
sudo rm -f \
  /usr/local/opnsense/www/js/widgets/SmartEndurance.js \
  /usr/local/opnsense/www/js/widgets/SmartEnduranceGauge.js \
  /usr/local/opnsense/www/js/widgets/Metadata/SmartEndurance.xml \
  /usr/local/opnsense/www/js/widgets/Metadata/SmartEnduranceGauge.xml

sudo configctl webgui restart

Troubleshooting
Widgets don’t appear in “Add widget”

Run installer again (permissions + metadata are common causes).

Restart Web GUI: sudo configctl webgui restart

Hard-refresh browser cache.

Dashboard widgets start failing

Remove custom widgets and restart Web GUI, then re-add carefully:

sudo rm -f /usr/local/opnsense/www/js/widgets/SmartEndurance*.js
sudo rm -f /usr/local/opnsense/www/js/widgets/Metadata/SmartEndurance*.xml
sudo configctl webgui restart

Notes

These widgets depend on the OPNsense SMART API endpoint:
/api/smart/service/*

Requires SMART to be enabled/working for your NVMe device.
EOF
