#!/bin/zsh
# Legt einmalig ein selbst signiertes Code-Signing-Zertifikat „EQLisa Local Signing“
# im Anmelde-Schlüsselbund an. Damit behält EQLisa über alle Builds und Updates dieselbe Identität,
# und macOS vergisst die Berechtigungen (Audio-Aufnahme, Browser-Steuerung) nicht bei jedem Update.
# WICHTIG: Den privaten Schlüssel sichern (Schlüsselbundverwaltung → Exportieren als .p12)!
# Geht er verloren, müssen alle Nutzer die Berechtigungen nach dem nächsten Update einmal neu erteilen.
set -e
NAME="EQLisa Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "✅ Zertifikat „$NAME“ ist schon vorhanden."; exit 0
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/cert.p12" -passout pass:eqlisa 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
  -out "$TMP/cert.p12" -passout pass:eqlisa
security import "$TMP/cert.p12" -k ~/Library/Keychains/login.keychain-db -P eqlisa -T /usr/bin/codesign >/dev/null
echo "✅ Zertifikat „$NAME“ angelegt."
