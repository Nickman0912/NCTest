FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Cloud Run sets PORT; gunicorn serves the Flask app.
CMD exec gunicorn --bind :$PORT --workers 1 --threads 8 --timeout 120 main:app
