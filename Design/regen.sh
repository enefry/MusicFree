#!/bin/bash
gen_app_icon.sh AppIcon.icon

cd ../
rm -rf  App/AppIcon.icon && cp -rf Design/AppIcon.icon  App/
rm -rf  App/Assets.xcassets/AppIcon.appiconset && cp -rf Design/AppIcon.appiconset App/Assets.xcassets/