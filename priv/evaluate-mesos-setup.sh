#!/bin/bash

echo "Removing old code."
rm -rf priv/evaluation

echo "Starting agent."
eval `ssh-agent -s`

echo "Current SSH_AUTH_SOCK:"
echo $SSH_AUTH_SOCK

echo "Installing key."
cp priv/ssh/evaluation /tmp/evaluation

echo "Changing permission on keys."
chmod 400 /tmp/evaluation

echo "Passphrase is set."
echo $EVALUATION_PASSPHRASE

echo "Adding key to agent."
( cd priv ; ./add_key.sh )

echo "Now SSH_AUTH_SOCK:"
echo $SSH_AUTH_SOCK

echo "After adding key, agent now contains the following"
ssh-add -l

GIT_SSH=ssh/wrapper
echo -n "Using the following wrapper: "
echo -n $GIT_SSH
echo

echo "Authentication socket."
echo $SSH_AUTH_SOCK

echo "Cloning evaluation code."
( cd priv; SSH_AUTH_SOCK=$SSH_AUTH_SOCK GIT_SSH=$GIT_SSH git clone git@github.com:lasp-lang/evaluation.git )
