#!/bin/zsh
# Creates throwaway certs for the repro in ./certs:
#   server CA + "localhost" server cert (trust ca.pem in the simulator)
#   client CA + client cert, bundled as client.p12 (password "repro")
# The extra flags are for macOS's LibreSSL: without -sha256 and named-curve
# EC params, BoringSSL (Envoy) rejects the certs.
set -e
cd "$(dirname "$0")" && mkdir -p certs && cd certs
EC=(-newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -pkeyopt ec_param_enc:named_curve -nodes -sha256)
ca() { openssl req -x509 $EC -days 30 -keyout $1.key -out $1.pem -subj "/CN=$2" \
         -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null; }
leaf() { # name CN ca ext
  openssl req $EC -keyout $1.key -out $1.csr -subj "/CN=$2" 2>/dev/null
  printf "$4" > $1.ext
  openssl x509 -req -sha256 -in $1.csr -CA $3.pem -CAkey $3.key -CAcreateserial -days 30 -extfile $1.ext -out $1.pem 2>/dev/null
}
ca ca "Repro Server CA"
leaf server localhost ca 'subjectAltName=DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\nkeyUsage=critical,digitalSignature\n'
ca client-ca "Repro Client CA"
leaf client "Repro Client" client-ca 'extendedKeyUsage=clientAuth\nkeyUsage=critical,digitalSignature\nbasicConstraints=critical,CA:FALSE\n'
openssl pkcs12 -export -inkey client.key -in client.pem -certfile client-ca.pem -name "Repro Client" -passout pass:repro -out client.p12
cp client.p12 ../../App/client.p12
echo "certs ready in $(pwd); client.p12 copied into App/"
