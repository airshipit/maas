#!/bin/bash

env_output=$(env)

# Loop through each line of the env output
while IFS= read -r line; do
    # Extract the variable name and value
    variable=$(echo "$line" | cut -d= -f1)
    value=$(echo "$line" | cut -d= -f2-)

    # Print the export command
    echo "export $variable=\"$value\""
done <<< "$env_output"

echo "Sleeping.............."
while true; do sleep 10; done
