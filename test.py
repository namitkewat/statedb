"""
Test suite for a custom Zig-based Redis implementation.

This script uses the pytest framework to run a series of tests against the
server. It includes two primary methods of testing:
1.  Raw Socket Communication: Sends manually crafted RESP (REdis Serialization
    Protocol) messages to test the server's protocol parser and command handling
    at a low level.
2.  High-Level Client: Uses the standard `redis-py` library to ensure
    compatibility with real-world Redis clients.

To run the tests, ensure the Zig Redis server is running and execute:
    pytest -v this_script_name.py
"""

import pytest
import redis
import socket
from typing import List, Union, Generator

# --- Configuration ---
REDIS_HOST: str = "localhost"
REDIS_PORT: int = 8080
CONN_TIMEOUT: float = 2.0  # seconds


# --- Helper Functions and Fixtures ---


def send_resp_command(command: List[Union[str, int]]) -> str:
    """
    Sends a command to the Redis server using a raw TCP socket.

    This function manually constructs a RESP message from the given command
    parts, sends it to the server, and returns the server's decoded response.
    This is useful for testing the server's RESP parsing logic directly.

    Args:
        command: A list of strings or integers representing the command
                 and its arguments (e.g., ["SET", "mykey", "myvalue"]).

    Returns:
        The server's response, decoded as a UTF-8 string and stripped of
        leading/trailing whitespace.
    """
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(CONN_TIMEOUT)
            s.connect((REDIS_HOST, REDIS_PORT))

            # Build the RESP protocol message as an array of bulk strings.
            # Example: ["SET", "key", "val"] -> *3\r\n$3\r\nSET\r\n$3\r\nkey\r\n$3\r\nval\r\n
            resp_parts = [f"*{len(command)}"]
            for part in command:
                part_str = str(part)
                resp_parts.append(f"${len(part_str)}")
                resp_parts.append(part_str)

            resp_message = "\r\n".join(resp_parts) + "\r\n"
            s.sendall(resp_message.encode("utf-8"))

            # Read the response from the server.
            return s.recv(4096).decode("utf-8").strip()
    except (socket.timeout, ConnectionRefusedError) as e:
        pytest.fail(
            f"Raw socket connection to {REDIS_HOST}:{REDIS_PORT} failed. "
            f"Is the Zig server running? Error: {e}"
        )


@pytest.fixture(scope="module")
def redis_client() -> Generator[redis.Redis, None, None]:
    """
    Pytest fixture that provides a connected redis-py client instance.

    This fixture is scoped to the "module", meaning it will create a single
    client connection and reuse it for all tests within this file. This is
    more efficient than creating a new connection for every test.

    Yields:
        A connected and ready-to-use redis.Redis client instance.
    """
    try:
        client = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)
        client.ping()  # Ensure the connection is valid before running tests.
        yield client
    except (redis.exceptions.ConnectionError, redis.exceptions.TimeoutError) as e:
        pytest.fail(
            f"redis-py client could not connect to {REDIS_HOST}:{REDIS_PORT}. "
            f"Is the Zig server running? Error: {e}"
        )


# --- Test Cases ---


def test_ping(redis_client: redis.Redis):
    """Tests the PING command for both clients."""
    # Test with redis-py client
    assert redis_client.ping() is True

    # Test with raw socket
    # PING returns a "Simple String" in RESP.
    response = send_resp_command(["PING"])
    assert response == "$4\r\nPONG"


def test_echo(redis_client: redis.Redis):
    """Tests the ECHO command."""
    # Test with redis-py client
    assert redis_client.echo("Hello Zig!") == "Hello Zig!"

    # Test with raw socket
    # ECHO returns a "Bulk String".
    response = send_resp_command(["ECHO", "Socket Test"])
    assert response == "$11\r\nSocket Test"


def test_client_setinfo(redis_client: redis.Redis):
    """Tests the CLIENT SETINFO command, which is part of the client handshake."""
    # redis-py sends CLIENT SETINFO automatically, but we can test it manually.
    # We use `execute_command` as `setinfo` is not a high-level function.
    assert (
        redis_client.execute_command("CLIENT", "SETINFO", "LIB-NAME", "MyZigRedis")
        == "OK"
    )
    assert redis_client.execute_command("CLIENT", "SETINFO", "LIB-VER", "1.0.0") == "OK"

    # Test with raw socket
    response = send_resp_command(["CLIENT", "SETINFO", "LIB-NAME", "RawSocketLib"])
    assert response == "+OK"
    response = send_resp_command(["CLIENT", "SETINFO", "LIB-VER", "1.2.3"])
    assert response == "+OK"


def test_set_get(redis_client: redis.Redis):
    """Tests basic SET and GET functionality."""
    # Test with redis-py client
    assert redis_client.set("test_key", "ZigValue") is True
    assert redis_client.get("test_key") == "ZigValue"

    # Test with raw socket
    response = send_resp_command(["SET", "socket_key", "RawValue"])
    assert response == "+OK"
    response = send_resp_command(["GET", "socket_key"])
    assert response == "$8\r\nRawValue"


def test_incr_decr(redis_client: redis.Redis):
    """Tests INCR, DECR, INCRBY, and DECRBY commands."""
    # Test with redis-py client
    redis_client.delete("counter")
    assert redis_client.incr("counter") == 1
    assert redis_client.incrby("counter", 4) == 5
    assert redis_client.decr("counter") == 4
    assert redis_client.decrby("counter", 2) == 2

    # Test with raw socket
    # All these commands return an "Integer" reply.
    send_resp_command(["DEL", "socket_counter"])
    response = send_resp_command(["INCR", "socket_counter"])
    assert response == ":1"
    response = send_resp_command(["INCRBY", "socket_counter", 10])
    assert response == ":11"
    response = send_resp_command(["DECR", "socket_counter"])
    assert response == ":10"
    response = send_resp_command(["DECRBY", "socket_counter", 5])
    assert response == ":5"


def test_del_exists(redis_client: redis.Redis):
    """Tests DEL and EXISTS commands."""
    # Test with redis-py client
    redis_client.set("del_test", "value")
    assert redis_client.exists("del_test") == 1
    assert redis_client.delete("del_test") == 1
    assert redis_client.exists("del_test") == 0

    # Test with raw socket
    send_resp_command(["SET", "socket_del", "temp"])
    response = send_resp_command(["EXISTS", "socket_del"])
    assert response == ":1"
    response = send_resp_command(["DEL", "socket_del"])
    assert response == ":1"
    response = send_resp_command(["EXISTS", "socket_del"])
    assert response == ":0"


def test_getdel(redis_client: redis.Redis):
    """Tests the GETDEL command, which gets a key and then deletes it."""
    # Test with redis-py client
    redis_client.set("getdel_test", "value")
    assert redis_client.execute_command("GETDEL", "getdel_test") == "value"
    assert redis_client.get("getdel_test") is None

    # Test non-existent key with redis-py
    assert redis_client.execute_command("GETDEL", "nonexistent") is None

    # Test wrong type (hash) with redis-py
    redis_client.hset("hash_key_getdel", "field", "value")
    with pytest.raises(redis.exceptions.ResponseError, match="WRONGTYPE"):
        redis_client.execute_command("GETDEL", "hash_key_getdel")
    assert redis_client.exists("hash_key_getdel") == 1  # Should not be deleted

    # --- Test with raw socket ---
    # Successful GETDEL
    send_resp_command(["SET", "socket_getdel", "socket_value"])
    response = send_resp_command(["GETDEL", "socket_getdel"])
    assert response == "$12\r\nsocket_value"
    response = send_resp_command(["EXISTS", "socket_getdel"])
    assert response == ":0"

    # Non-existent key should return a "Null Bulk String".
    response = send_resp_command(["GETDEL", "socket_missing"])
    assert response == "$-1"

    # Wrong type should return an error.
    send_resp_command(["HSET", "socket_wrong_type", "field", "value"])
    response = send_resp_command(["GETDEL", "socket_wrong_type"])
    assert "WRONGTYPE" in response
    response = send_resp_command(["EXISTS", "socket_wrong_type"])
    assert response == ":1"  # Key should still exist.

    # Error: Wrong number of arguments
    response = send_resp_command(["GETDEL"])
    assert "ERR wrong number" in response
    response = send_resp_command(["GETDEL", "too", "many", "args"])
    assert "ERR wrong number" in response


def test_flushdb(redis_client: redis.Redis):
    """Tests the FLUSHDB command."""
    # Test with redis-py client
    redis_client.set("flush_test", "value")
    assert redis_client.flushdb() is True
    assert redis_client.exists("flush_test") == 0

    # Test with raw socket
    send_resp_command(["SET", "socket_flush", "temp"])
    response = send_resp_command(["FLUSHDB"])
    assert response == "+OK"
    response = send_resp_command(["EXISTS", "socket_flush"])
    assert response == ":0"


def test_type(redis_client: redis.Redis):
    """Tests the TYPE command for various data types."""
    # Test with redis-py client
    redis_client.set("string_key", "value")
    redis_client.hset("hash_key", "field", "value")
    assert redis_client.type("string_key") == "string"
    assert redis_client.type("hash_key") == "hash"
    assert redis_client.type("non_existent_key") == "none"

    # Test with raw socket
    send_resp_command(["SET", "socket_type_str", "value"])
    send_resp_command(["HSET", "socket_type_hash", "field", "value"])
    response = send_resp_command(["TYPE", "socket_type_str"])
    assert response == "+string"
    response = send_resp_command(["TYPE", "socket_type_hash"])
    assert response == "+hash"
    response = send_resp_command(["TYPE", "socket_type_none"])
    assert response == "+none"


def test_hset_hget_hgetall(redis_client: redis.Redis):
    """Tests HSET, HGET, and HGETALL for hash manipulation."""
    # Test with redis-py client
    assert redis_client.hset("user:1000", "name", "Alice") == 1
    assert redis_client.hset("user:1000", "email", "alice@zig.com") == 1
    assert redis_client.hget("user:1000", "name") == "Alice"
    assert redis_client.hgetall("user:1000") == {
        "name": "Alice",
        "email": "alice@zig.com",
    }

    # Test with raw socket
    response = send_resp_command(["HSET", "socket_user", "field1", "value1"])
    assert response == ":1"
    response = send_resp_command(["HSET", "socket_user", "field2", "value2"])
    assert response == ":1"
    response = send_resp_command(["HGET", "socket_user", "field1"])
    assert response == "$6\r\nvalue1"

    # Test HGETALL with raw socket. The order of key-value pairs in a hash
    # is not guaranteed, so we must check for both possible orderings.
    response = send_resp_command(["HGETALL", "socket_user"])
    expected1 = "*4\r\n$6\r\nfield1\r\n$6\r\nvalue1\r\n$6\r\nfield2\r\n$6\r\nvalue2"
    expected2 = "*4\r\n$6\r\nfield2\r\n$6\r\nvalue2\r\n$6\r\nfield1\r\n$6\r\nvalue1"
    assert response in (expected1, expected2)


# This allows the script to be run directly.
if __name__ == "__main__":
    # The '-v' flag enables verbose output.
    pytest.main(["-v", __file__])
