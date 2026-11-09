---
layout: ../../layouts/MarkdownPostLayout.astro
title: 'You should know about TLS'
pubDate: 2026-11-09
description: 'Learning log about TLS1.2'
author: 'tyzerrr'
---

# If you are a developer, you need to know about TLS
HTTPS is an extension of the HTTP protocol.
It encrypts transmitted data with TLS (Transport Layer Security), which can protects against attack like tampering.

When we publish a service to the Internet, we need to get a domain and provide encrypted communication with HTTPS to users.

Taking AWS as an example, we need to get a domain on Route53, set up name server for DNS resolution, issue certificate on ACM, register CNAME records for DNS validation to hosted zone, attach certificate to ALB, add A record for CloudFront, ALB.
We are able to build this kind of infrastructure with AI Agent as IaC code like Terraform easily.

However, we can find many developers who can not answer fundamental questions kike "What is DNS" or "How does HTTPS work?", including myself.
In this post, I share what I learned about TLS which supports HTTPS.

This post is written by a human, it might contain some mistakes.

# What is TLS?
TLS stands for Transport Layer Security.
TLS consists of four steps as shown in the diagram below. (We only touch TLS1.2 here. TLS1.3, latest version of TLS that is supported by almost all major brosers is an extension of TLS1.2, I decided it's not the best starting point to understand the fundamentals of TLS.)

![HTTPS illustrated](/images/https-illustrated.png)

## 1. TCP Handshake
TLS is a protocol that runs over TCP.
Before the TLS handshake can begin, a TCP connection needs to be established.  

Let's look at how the TCP handshake works.  
At first, the client sends a connection request (SYN) with sequence number initialized randomlyto the server.  
The Server checks the sequence number sent from the client, acknowledges the connection request.  
It then sends back a response(SYN+ACK) containing its own sequence number to the client.  
The client checks the sequence number sent from the server, and sends an acknowledement(ACK) back to the server, which establishes the TCP connection.  


## 2. Certificate Check
The second step of TLS is the certificate check.  
In this step, the client and the server agree on the cipher suite and the TLS version.  

First, the client tells the server what cipher suites and which version of TLS it supports (Client Hello).  
Then the server chooses the ones to actually use for the connection and sends its choise back to the client (Server Hello).  

Next, the server sends its certificate to the client.  
The certificate contains a public key of the server, anything encrypted with this public key can only be decrypted with the private key stored on the server.  

## 3. Key Exchange
The third step is the exchange.  
As its name implies, the client and the server exchange the key used for the connection.  

The specific algorithm depends on the cipher suite, but let's look at the case using RSA.  
With RSA, the client encrypts a session key it has genertated with the server's public key and sends it to the server(Client Key Exchange).  
The Server stores a paird private key, so the encrypted session key can only be decrypted with server's private key.  
This asymmetry ensures that only the client and the server that established the connection can decrypt the encrypted communication.  

Once the key exchange is complete, both the client and the server send the `Change Cipher Spec` message.  
This message signals that "we use this encrypted session key on this connection from now on".  
The Finished message that follows verifies that the handshake messages exchanged so far haven't been tampered with.   
It contains a hash value computed from the entire handshake.   
Once both sides have verified each other's Finished message, the key exchange is complete.  

## Why not use asymmetric encryption for all communication?
You may wonder why we do not generate another key pair with an asymetric algorithm.
This is possible, but asymmetric decryption taks high calculation cost, so it is not proper for sending large amount of data.

## 4. Data Transmission
The last step is the data transmission.  
Using the session key shared in the key exchange step, the client and the server encrypt their communication with symmetric encryption.  
Symmetric encryption is less computationally expensive than asymmetric encryption, so it can handle large amounts of data efficiently.  


## Notes about changes from TLS1.2 to TLS1.3
TLS 1.3 reduced the number of network round trips in the handshake to one, improving performance.  
It also unified the available key exchange methods into ECDHE and cleaned up the available encryption algorithms, making them more secure and consistent.  
For more details, see [this article](https://zenn.dev/nttdata_tech/articles/9beb886173eaa2) (in Japanese).  

# Summary
In short, TLS provides fully encrypted communication at a low computational cost by using symmetric encryption with a session key that is protected by asymmetric encryption.  
I hope this post helps as many developers as possible gain a basic understanding of TLS and do even better work.  
I plan to keep sharing what I learn on this blog.  
