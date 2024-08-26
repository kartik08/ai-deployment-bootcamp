from google.cloud import bigquery

import json
from constants import TFVARS
import argparse


storage_directory = "../../../data"
with open(f"{storage_directory}/meta.json", "r") as f:
    meta_data = json.load(f)

keys = meta_data.keys()

parser = argparse.ArgumentParser(description="Parser for cmdline arguments")
parser.add_argument('--datasetname', type=str, required=True, help=f"choose from {str(list(keys))}")
args = parser.parse_args()

upload_data = {}
with open(f"{storage_directory}/{args.datasetname}.json") as f:
    df = json.load(f)

supported_task_types = ["Summarization", "Translation"]
task_type = meta_data[args.datasetname]["type"]
if task_type not in supported_task_types:
    print(f"Task type '{task_type}' is not supported. Supported task types: {supported_task_types}")
    exit()

bq_client = bigquery.Client()
project_prefix = TFVARS["project"].replace("-", "_")
data_table = bq_client.get_table(f"{TFVARS['project']}.{project_prefix}_{TFVARS['env']}_database.data_table")

last_id_query = bq_client.query(f"SELECT max(id) as max_id from {data_table}")
last_id = None
for lid in last_id_query.result():
    last_id = lid.get("max_id", 0)

last_id = last_id if last_id is not None else 0
data_list = []
for i in range(len(df)):
    if task_type == ("Summarization"):
        data = df[i][meta_data[args.datasetname]["data"]]

    elif task_type == "Translation":
        base_key = meta_data[args.datasetname]["data"][0]
        data = df[i][base_key][meta_data[args.datasetname]["data"][1]]

    data_point = {"id": last_id + 1, "data": data}
    data_list.append(data_point)
    last_id += 1
    
errors = bq_client.insert_rows_json(data_table, data_list)

if errors is not None and len(errors) > 0:
    print(f"Error saving data to table: {errors}")
else:
    print(f"Data point added: {data_point}")