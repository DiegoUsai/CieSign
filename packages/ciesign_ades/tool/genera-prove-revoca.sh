#!/usr/bin/env bash
# Genera le prove per i test di revoca (OCSP e CRL) e di sbustamento:
# una CA di prova, due titolari (uno valido, uno revocato), una CRL firmata,
# risposte OCSP firmate dalla CA, un PDF con allegato e uno zip.
# Nessun valore legale: servono solo ai test automatici.
set -euo pipefail
OUT="$(cd "$(dirname "$0")/.." && pwd)/test/resources/revoca"
W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$OUT"; cd "$W"
cat > ca.cnf <<'C'
[ca]
default_ca = d
[d]
database = index.txt
new_certs_dir = .
serial = serial
crlnumber = crlnumber
default_md = sha256
default_crl_days = 3650
policy = p
copy_extensions = none
[p]
commonName = supplied
[sig]
basicConstraints = critical,CA:false
keyUsage = critical,nonRepudiation,digitalSignature
authorityInfoAccess = OCSP;URI:http://ocsp.prova.invalid/,caIssuers;URI:http://ca.prova.invalid/ca.der
crlDistributionPoints = URI:http://crl.prova.invalid/ca.crl
C
touch index.txt; echo 1000 > serial; echo 01 > crlnumber
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 3650 -subj "/CN=CA di prova CIE Sign/O=CIE Sign test" -sha256 2>/dev/null
for n in valido revocato; do
  openssl req -newkey rsa:2048 -nodes -keyout $n.key -out $n.csr -subj "/CN=Titolare $n" 2>/dev/null
  openssl ca -batch -config ca.cnf -cert ca.pem -keyfile ca.key -in $n.csr -out $n.pem -days 3000 -extensions sig -startdate 20250101000000Z 2>/dev/null
done
openssl ca -config ca.cnf -cert ca.pem -keyfile ca.key -revoke revocato.pem -crl_reason keyCompromise -crl_compromise 20260301120000Z 2>/dev/null
openssl ca -gencrl -config ca.cnf -cert ca.pem -keyfile ca.key -out ca.crl.pem 2>/dev/null
openssl crl -in ca.crl.pem -outform der -out "$OUT/ca.crl"
for n in ca valido revocato; do openssl x509 -in $n.pem -outform der -out "$OUT/$n.der"; done
openssl pkcs8 -topk8 -nocrypt -in valido.key -outform der -out "$OUT/valido.pk8"
for n in valido revocato; do
  openssl ocsp -issuer ca.pem -cert $n.pem -no_nonce -reqout $n.req 2>/dev/null
  openssl ocsp -index index.txt -rsigner ca.pem -rkey ca.key -CA ca.pem -reqin $n.req -respout "$OUT/ocsp-$n.der" -ndays 3650 2>/dev/null
done
# PDF con un allegato e zip con due file, per lo sbustamento.
python3 - "$W" <<'P'
import sys
from pypdf import PdfWriter
w = PdfWriter(); w.add_blank_page(595, 842)
w.add_attachment("capitolato.txt", b"Capitolato di prova\n")
w.write(sys.argv[1] + "/con-allegato.pdf")
P
cp con-allegato.pdf "$OUT/con-allegato.pdf"
mkdir z && printf 'offerta\n' > z/offerta.txt && cp con-allegato.pdf z/ && (cd z && zip -q -r ../gara.zip offerta.txt con-allegato.pdf)
cp gara.zip "$OUT/gara.zip"
echo "Prove generate in $OUT"
