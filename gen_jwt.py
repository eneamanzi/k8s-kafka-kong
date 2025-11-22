import jwt, time

secret = "supersecret"
key = "exam-client-key"

payload = {
    "iss": key,
    "sub": "enea",
    "role": "exam-client",
    "exp": int(time.time()) + 3600  # valido per 1 ora
}

token = jwt.encode(payload, secret, algorithm="HS256")
print(token)
