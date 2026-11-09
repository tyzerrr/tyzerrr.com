---
layout: ../../layouts/MarkdownPostLayout.astro
title: 'You should know about TLS'
pubDate: 2026-11-09
description: 'Learning log about TLS1.2'
author: 'tyzerrr'
---

# If you are a developer, you need to know about TLS
HTTPSプロトコルはHTTPプロトコルの拡張で、TLSで通信内容を暗号化することで、第三者による通信内容の傍受を防ぐことができます。
私たちは何かのサービスをインターネット上に公開する際には、ドメインを取得し、HTTPSプロトコルで暗号化された通信をサービスの利用者に提供する必要があります。
AWSを例にすると、Route53でドメインを取得し、DNS解決を行うネームサーバをHostedZoneに登録し、ACMで証明書を発行して、DNS検証用のCNAMEレコードをHostedZoneに登録し、ALB等にACMで発行した証明書をアタッチして、ALBやCloudFront用のAレコードを追加する必要があります。
このようなインフラストラクチャは、TerraformなどのIaCを用いれば、AI Agentでも簡単に構築できます。
しかし、「DNSとは何か？」、「HTTPSプロトコルはどのように実現されるか？」といった本質的な問いに答えられない開発者は、私を含めて少なくないはずです。
この記事では、HTTPSプロトコルの実現を支えるTLSについて、私が学習した内容をまとめて共有します。

こちらの記事は全て人間が書いたものであり、多少の間違いが含まれる可能性があります。

# What is TLS?
TLSはTransport Layer Securityの略です。
TLSは、以下の図に示すように4つのStepから構成されます。(尚、ここではTLS1.2のみについて説明します。現在の主要なBrowserでサポートされる最新のTLS1.3はTLS1.2の拡張であり、TLSを理解するための題材として適切でないと判断しました。)
以下で各Stepについて説明します。

![HTTPS illustrated](/images/https-illustrated.png)

## 1. TCP Handshake
TLSはTCP上で動作するプロトコルであり、TLS handshakeが始まる前提として、まずTCPコネクションが確立されている必要があります。
この前提となるTCP Handshakeについて説明します。
まず最初にClientからServerに、ランダムに初期化されたシーケンス番号を添えて接続要求(SYN)を送ります。
ServerはClientのシーケンス番号を確認して、接続要求をACKし、自身のシーケンス番号を添えて、Clientに接続確認(SYN+ACK)を送り返します。
ClientはServerのシーケンス番号を確認し、ACK(接続確認)をServerに送信することで、TCPコネクションが確立されます。

## 2. Certificate Check
TLSの2つ目のStepはCertificate Checkです。
このStepでは、通信暗号化に利用するCipherSuite、TLSのバージョンについてClientとServerで合意します。
まず、Clientは自身がSupportするTLSバージョンやCipherSuiteをServerに送り(Client Hello)、Serverはその内容から、実際に通信に利用する暗号化プロトコルを選択してClientに返します(Server Hello)。
次にServerはClientに証明書を送信します。
証明書には、サーバの公開鍵が含まれており、この公開鍵で暗号化された内容は、サーバに保存された秘密鍵でのみ復号化されます。

## 3. Key Exchange
TLSの3つ目のStepはKey Exchangeです。
名前の通り、このStepではClientとServerが通信に利用する鍵を交換します。
具体的なアルゴリズムは、利用するCipherSuiteによって異なりますが、ここでは最も理解しやすいRSAを用いて説明します。
RSAでは、Clientで生成したセッション鍵をサーバーの公開鍵で暗号化しServerに送信します(Client Key Exchange)。
Serverには公開鍵と対になる秘密鍵が保存されており、暗号化されたセッション鍵は、サーバの秘密鍵でのみ復号できます。
この非対称性によって、暗号化された通信を解読できるのは、通信を確立したClientとServerのみであることが保証されます。

鍵の交換が終わると、ClientとServerはそれぞれ`Change Cipher Spec`を送り合います。これは「これ以降の通信は、今合意したセッション鍵による暗号化方式で行う」という合図です。
続けて送られる`Finished`は、それまでのhandshakeでやり取りした内容が改ざんされていないことを確認するためのメッセージで、handshake全体の内容から計算したハッシュ値が含まれています。双方が`Finished`を検証できれば、Key Exchangeは完了です。

## 全ての通信を非対称アルゴリズムで生成された鍵で行わないのは何故か？
サーバの公開鍵と秘密鍵のような、非対称アルゴリズムで生成された、もう一組の鍵を生成して通信の暗号化に用いる方法も考えられます。
確かに原理的には可能ですが、非対称アルゴリズムの復号化は対称アルゴリズムのそれと比べて、計算コストが高く、大量のデータ送信に向いていません。

## 4. Data Transmission
TLSの4つ目のStepはData Transmissionです。
Key Exchangeで共有したセッション鍵を使い、ClientとServerは対称暗号化によって通信内容を暗号化してやり取りします。対称暗号化は非対称暗号化と比べて計算コストが低いため、大量のデータを効率よくやり取りできます。

## Notes about changes from TLS1.2 to TLS1.3
TLS1.3はHandshakeのネットワークラウンドトリップの回数を1回に減らし、パフォーマンスを向上させました。
また、利用可能な鍵交換方法をECDHEに統一し、利用可能な暗号化アルゴリズムを整理して、より安全で統一されたものに変更しました。
詳しくは、[こちらの記事](https://zenn.dev/nttdata_tech/articles/9beb886173eaa2)を参照してください。

# まとめ
TLSは、非対称アルゴリズムによって暗号化されたセッション鍵による対称暗号化によって、低い計算コストで完全に暗号化された通信を提供する仕組みと言えます。
この記事を通して1人でも多くの開発者がTLSの基本的な知識を身につけ、より良い仕事と成果を生み出せることを願います。
これからも継続的に私の学びをブログとして公開する予定です。
