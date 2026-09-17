.PHONY: package init plan apply smoke-ingest backfill destroy

package:
	bash scripts/package_lambda.sh

init:
	cd terraform && terraform init -backend-config=backend.hcl

plan: package
	cd terraform && terraform plan -out=tfplan

apply: package
	cd terraform && terraform apply

smoke-ingest:
	aws lambda invoke --function-name nyc-taxi-ingest --cli-binary-format raw-in-base64-out --payload '{"year":2024,"month":1}' --region us-east-1 /tmp/nyc-taxi-ingest.json
	cat /tmp/nyc-taxi-ingest.json

backfill:
	aws glue start-job-run --job-name nyc-taxi-historical-backfill --region us-east-1

destroy:
	cd terraform && terraform destroy
