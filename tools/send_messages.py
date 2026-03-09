"""Send test messages to Azure Service Bus queue.

Usage:
    cd tools
    uv run python send_messages.py
    uv run python send_messages.py -n 5
    uv run python send_messages.py -c "<connection-string>" -n 20
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from azure.servicebus import ServiceBusClient, ServiceBusMessage
from dotenv import load_dotenv

# Load .env from the same directory as this script
load_dotenv(Path(__file__).parent / ".env")


def _az(*args: str) -> str:
    """Run an az CLI command and return trimmed stdout."""
    az_path = shutil.which("az") or shutil.which("az.cmd")
    if not az_path:
        print("Error: Azure CLI (az) not found on PATH")
        sys.exit(1)
    result = subprocess.run(
        [az_path, *args],
        capture_output=True, text=True, check=True,
    )
    return result.stdout.strip()


def get_connection_string(resource_group: str) -> str:
    """Discover the Service Bus namespace and return its connection string."""
    ns = _az(
        "servicebus", "namespace", "list",
        "--resource-group", resource_group,
        "--query", "[0].name", "-o", "tsv",
    )
    if not ns:
        print(f"No Service Bus namespace found in resource group '{resource_group}'")
        sys.exit(1)

    conn = _az(
        "servicebus", "namespace", "authorization-rule", "keys", "list",
        "--namespace-name", ns,
        "--resource-group", resource_group,
        "--name", "FunctionAppRule",
        "--query", "primaryConnectionString", "-o", "tsv",
    )
    if not conn:
        print("Could not retrieve Service Bus connection string")
        sys.exit(1)
    return conn


def send(connection_string: str, queue_name: str, message_count: int) -> None:
    print("========================================")
    print(" Service Bus Message Sender")
    print("========================================")
    print(f"Queue     : {queue_name}")
    print(f"Messages  : {message_count}")
    print()

    client = ServiceBusClient.from_connection_string(connection_string.strip())
    sender = client.get_queue_sender(queue_name)

    with client, sender:
        batch = sender.create_message_batch()
        total_sent = 0
        batch_count = 0

        for i in range(1, message_count + 1):
            body = json.dumps({
                "id": i,
                "message": f"Demo message #{i}",
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "source": "send_messages.py",
            })
            try:
                batch.add_message(ServiceBusMessage(body))
                batch_count += 1
            except ValueError:
                sender.send_messages(batch)
                total_sent += batch_count
                print(f"  Sent batch of {batch_count} messages ({total_sent}/{message_count})")
                batch = sender.create_message_batch()
                batch.add_message(ServiceBusMessage(body))
                batch_count = 1

        if batch_count > 0:
            sender.send_messages(batch)
            total_sent += batch_count
            print(f"  Sent batch of {batch_count} messages ({total_sent}/{message_count})")

    print()
    print(f"Done! Sent {total_sent} messages to '{queue_name}'.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Send messages to Service Bus queue")
    parser.add_argument("--resource-group", "-g",
                        default=os.getenv("RESOURCE_GROUP"),
                        help="Azure resource group (auto-discovers connection string)")
    parser.add_argument("--connection-string", "-c",
                        default=os.getenv("SERVICE_BUS_CONNECTION_STRING"),
                        help="Service Bus connection string")
    parser.add_argument("--count", "-n", type=int,
                        default=int(os.getenv("MESSAGE_COUNT", "10")),
                        help="Number of messages to send (default: 10)")
    parser.add_argument("--queue", "-q",
                        default=os.getenv("QUEUE_NAME", "demo-queue"),
                        help="Queue name (default: demo-queue)")

    args = parser.parse_args()

    if args.connection_string:
        conn = args.connection_string
    elif args.resource_group:
        conn = get_connection_string(args.resource_group)
    else:
        print("Error: Provide --connection-string, --resource-group, or set them in .env")
        parser.print_help()
        sys.exit(1)

    send(conn, args.queue, args.count)


if __name__ == "__main__":
    main()
