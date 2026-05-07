#!/bin/bash

echo "Updating packages..."
sudo apt update
echo "Complete."
echo "Upgrading packages..."
sudo apt upgrade -y
echo "System update complete."
