import streamlit as st
import requests
import json
from google.cloud import storage
from google.cloud import documentai_v1 as documentai
from google.cloud import aiplatform_v1, aiplatform
from fastapi import FastAPI, File, UploadFile, Body
from fastapi.responses import JSONResponse
from fastapi.middleware.wsgi import WSGIMiddleware
import os
import sys
import uvicorn
from google.api import httpbody_pb2  # Add this import
# Adjust the sys.path to ensure compatibility for both FastAPI and Streamlit
sys.path.append(os.path.dirname(os.path.abspath(__file__)))

# Use relative import for FastAPI and absolute import for Streamlit
try:
    from .models import LlamaTask, Models  # For FastAPI
except ImportError:
    from models import LlamaTask,Models 

# Configuration
ENDPOINT_ID = os.getenv("ENDPOINT_ID")
MODEL_NAME = os.getenv("MODEL_NAME")
ZONE = os.getenv("ZONE")
REGION = f"{ZONE.split('-')[0]}-{ZONE.split('-')[1]}"
PROJECT_ID = os.getenv("PROJECT_ID")
PROJECT_NUMBER = os.getenv("PROJECT_NUMBER")
ENV = os.getenv("ENV")
PROJECT_PREFIX = PROJECT_ID.replace("-", "_")
BUCKET_NAME = "bmo-team-2"
DOCUMENT_REGION="us"
AUTH_TOKEN = os.getenv("AUTH_TOKEN")
PROCESSOR_ID="434e9199c75b67e0"
# Initialize FastAPI
app = FastAPI()


@app.post("/predict")
async def predict(text: str = Body(None), num_tokens: int = Body(...), file: UploadFile = None, summary_length: str = Body(None),  summary_style: str = Body(None)):
    
    if file:
        client = storage.Client()
        
        
        
       
        bucket = client.bucket(BUCKET_NAME)
        folder_name = "input_files"
        blob = bucket.blob(f"{folder_name}/{file.filename}")
        blob.upload_from_string(file.file.read())
        file_url = f"gs://{BUCKET_NAME}/{folder_name}/{file.filename}"
        print("------", file_url)
        docai_client = documentai.DocumentProcessorServiceClient()
        name = f"projects/{PROJECT_ID}/locations/{DOCUMENT_REGION}/processors/PROCESSOR_ID"  # Replace PROCESSOR_ID with your processor ID
        #raw_document = documentai.RawDocument(content=file.file.read(), mime_type="application/pdf")
        #request = documentai.ProcessRequest(name=name, raw_document=raw_document)
        #result = docai_client.process_document(request=request)
        #text = result.document.text
        
        docai_client = documentai.DocumentProcessorServiceClient()
        name = docai_client.processor_path(PROJECT_ID, DOCUMENT_REGION, PROCESSOR_ID)
        input_uri = file_url
        document = documentai.types.GcsDocument(
                        gcs_uri=input_uri,
                        mime_type="application/pdf"
            )    
           

        # Create the request with the GCS document
        request = documentai.types.ProcessRequest(
        name=name,
        raw_document=None,  # No raw document since we're using GCS document
        gcs_document=document  # Directly include the GCS document here
        )       

        result = docai_client.process_document(request=request)
        text = result.document.text
    

    if not text:
        return JSONResponse(content={"error": "Text input is required."}, status_code=400)
    task= LlamaTask.SUMMARIZATION
    input_data = Models.get_input_for_model_name(MODEL_NAME, text, task, summary_length, summary_style)
    input_data["max_tokens"] = num_tokens
    prediction_client = aiplatform_v1.PredictionServiceClient(
        client_options={
            "api_endpoint": f"{REGION}-aiplatform.googleapis.com",
        }
    )
    json_data = json.dumps(input_data)
    http_body = httpbody_pb2.HttpBody(data=json_data.encode("utf-8"), content_type="application/json")
    print(json_data)
    request = aiplatform_v1.RawPredictRequest(
        endpoint=f"projects/{PROJECT_NUMBER}/locations/{REGION}/endpoints/{ENDPOINT_ID}",
        http_body=http_body,
    )
    print(">>>>>>>>>>>>>>>>>>",request)
    response = prediction_client.raw_predict(request)
    return {"prediction": json.loads(response.data)}

# Mount FastAPI app to Streamlit
st_app = FastAPI()
st_app.mount("/api", app)

# Streamlit UI
st.set_page_config(page_title="BMO Document Summarizer", page_icon=":bank:")
st.markdown("""
    <style>
    .main {
        background-color: #e6eff9;
    }
    h1 {
        color: #004d98;
    }
    .sidebar .sidebar-content {
        background-color: #004d98;
    }
    .css-1d391kg {
        color: #ffffff;
    }
    .css-1d391kg:focus {
        background-color: #e6eff9;
    }
    </style>
""", unsafe_allow_html=True)

# BMO Logo
# logo_url = "https://upload.wikimedia.org/wikipedia/en/8/88/BMO_Financial_Group_logo.svg"
# st.image(logo_url, width=200)

st.title("Document Summarizer")

uploaded_file = st.file_uploader('Please upload a PDF file')
news_text = st.text_area('Or paste news text here')
num_tokens = st.slider('Select number of tokens for summarization', min_value=50, max_value=1000, value=200)
summary_length = st.selectbox(label = 'Select Summary Length', options = ['Concise', 'Detailed'])
summary_style = st.selectbox(label = 'Select Summary Style', options = ['Executive Summary', 'Conversational Summary', 'Analytical Summary', 'Bullet Point Style', 'Descriptive Style', 'Formal Style', 'Narrative Style'])

st.form_submit_button(label="Submit", help=None, on_click=None, args=None, kwargs=None, type="secondary", icon=None, disabled=False, use_container_width=False)

def call_backend(text, num_tokens, summary_length, summary_style, uploaded_file=None):
    if uploaded_file:
        files = {'file': uploaded_file}
    else:
        files = None

    payload = {
        "text": text,
        "num_tokens": num_tokens,
        "summary_length":summary_length,
        "summary_style":summary_style
    }

    response = requests.post("http://35.223.159.99:8080/predict", files=files, data=payload)
    if response.status_code == 200:
        return response.json().get("prediction")
    else:
        return "Error: Something went wrong."

if uploaded_file is not None:
    st.write("File uploaded successfully.")
    summary = call_backend(text="", num_tokens=num_tokens, summary_length= summary_length, summary_style = summary_style, uploaded_file=uploaded_file)
    # Extract the output text
    output_text = summary['predictions'][0].split("Output:")[-1]

    # Clean up the output text
    output_text = output_text.replace("\\n", "\n").strip()
    st.subheader('Summarized File Content')
    st.write(output_text)

if news_text:
    summary = call_backend(text=news_text, num_tokens=num_tokens, summary_length= summary_length, summary_style = summary_style)
    # Extract the output text
    output_text = summary['predictions'][0].split("Output:")[-1]

    # Clean up the output text
    output_text = output_text.replace("\\n", "\n").strip()
    st.subheader('Summarized Content')
    st.write(output_text)

