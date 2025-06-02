# server.py
from flask import Flask, request, jsonify

app = Flask(__name__)

@app.route("/setting", methods=["POST"])
def save_settings():
    data = request.get_json(force=True)
    print("Got:", data)
    # TODO: validate and persist
    return jsonify(success=True)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
