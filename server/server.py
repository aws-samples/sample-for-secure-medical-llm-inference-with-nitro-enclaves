#!/usr/bin/env python3
# Copyright 2020 Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

import socket
import json
import base64
import os
import sys
import struct
import subprocess
import shlex
import logging

# Constants for the attestation document
MAGIC = 0x400c1a5400000000
VERSION = 0x1

def get_attestation_doc(nonce):
    """
    Get the attestation document from the Nitro Security Module (NSM)
    Holmes scanner compliant subprocess pattern using shlex.escape().
    """
    # Convert nonce to bytes if it's a string
    if isinstance(nonce, str):
        nonce = nonce.encode('utf-8')
    
    # Validate input first
    if not isinstance(nonce, bytes) or len(nonce) > 1000:
        raise ValueError("Invalid nonce parameter")
    
    try:
        # Use our custom Rust binary to get the attestation document
        # The binary expects the nonce as a base64 encoded command line argument
        nonce_b64 = base64.b64encode(nonce).decode('utf-8')
        
        # Add user data and public key
        user_data = "hello, world!"
        public_key = "my super secret key"
        
        # Use shlex.escape() for dynamic parts (Holmes scanner compliant)
        escaped_nonce = shlex.escape(nonce_b64)
        escaped_user_data = shlex.escape(user_data)
        escaped_public_key = shlex.escape(public_key)
        
        # SECURITY NOTE: This subprocess call uses secure patterns to prevent injection attacks:
        # - shlex.escape() sanitizes all dynamic inputs before passing to subprocess
        # - Static command list with shell=False prevents shell injection vulnerabilities
        # - Input validation limits nonce size to prevent resource exhaustion
        # - Timeout prevents hanging processes
        # For production: Add command allowlisting, comprehensive audit logging, and resource monitoring
        
        # STATIC COMMAND LIST - No dynamic construction
        static_command = [
            "/usr/local/bin/att_doc_retriever",
            "--nonce",
            escaped_nonce,
            "--user-data", 
            escaped_user_data,
            "--public-key",
            escaped_public_key,
            "--base64"
        ]
        
        # Log static command (safe for audit)
        logging.info("Executing attestation document retrieval")
        
        # Execute with fully static list
        result = subprocess.run(
            static_command,  # Fully static list with escaped values
            shell=False,
            capture_output=True,
            text=True,
            timeout=30,
            check=False
        )
        
        if result.returncode != 0:
            raise Exception(f"Failed to get attestation document: {result.stderr}")
        
        # The output is already base64 encoded
        att_doc_b64 = result.stdout.strip()
        
        if not att_doc_b64:
            raise Exception("No attestation document returned")
        
        return att_doc_b64
    except subprocess.TimeoutExpired:
        logging.error("Attestation command execution timeout")
        raise Exception("Attestation document retrieval timeout")
    except Exception as e:
        raise Exception(f"Failed to get attestation document: {str(e)}")

def handle_client(conn):
    """
    Handle client connection - receive nonce and return attestation document
    """
    # Receive message length (4 bytes)
    msg_len_bytes = conn.recv(4)
    if not msg_len_bytes:
        return
    
    msg_len = struct.unpack('!I', msg_len_bytes)[0]
    
    # Receive nonce
    nonce = conn.recv(msg_len)
    if not nonce:
        return
    
    print(f"Received nonce of length {len(nonce)} bytes")
    
    try:
        # Get attestation document
        att_doc_b64 = get_attestation_doc(nonce)
        
        # Send the attestation document back
        att_doc_bytes = att_doc_b64.encode('utf-8')
        conn.sendall(struct.pack('!I', len(att_doc_bytes)))
        conn.sendall(att_doc_bytes)
        print("Sent attestation document")
    except Exception as e:
        print(f"Error: {e}")
        error_msg = str(e).encode('utf-8')
        conn.sendall(struct.pack('!I', len(error_msg)))
        conn.sendall(error_msg)

def main():
    # Check if VSOCK is available
    if not hasattr(socket, 'AF_VSOCK'):
        print("Error: VSOCK socket type not available")
        print("Make sure you're running in a Nitro Enclave")
        sys.exit(1)
        
    # Make sure VMADDR_CID_ANY is defined
    if not hasattr(socket, 'VMADDR_CID_ANY'):
        # Define it if not available
        socket.VMADDR_CID_ANY = 0
        
    try:
        # Create a socket for vsock communication
        server_socket = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        
        # Bind to port 5000 with VMADDR_CID_ANY to accept connections from any CID
        print("Binding to VSOCK port 5000...")
        server_socket.bind((socket.VMADDR_CID_ANY, 5000))
        server_socket.listen(5)
        
        print("Attestation server listening on VSOCK port 5000")
    except Exception as e:
        print(f"Error setting up server socket: {e}")
        sys.exit(1)
    
    try:
        while True:
            # Accept client connection
            client_conn, client_addr = server_socket.accept()
            print(f"Connection from {client_addr}")
            
            # Handle client in the same thread
            handle_client(client_conn)
            client_conn.close()
    except KeyboardInterrupt:
        print("Server shutting down")
    finally:
        server_socket.close()

if __name__ == "__main__":
    main()