# Per-clinic Cal.com image repo. Cal.com bakes NEXT_PUBLIC_WEBAPP_URL at BUILD
# time, so CI builds one image per clinic domain and pushes it here:
#   docker build --build-arg NEXT_PUBLIC_WEBAPP_URL=https://cal.<clinic>.<apex> ...
#   docker push <repo_url>:<tag>
# On first apply the repo is empty and the service stays unhealthy until CI
# pushes the image, then `aws ecs update-service --force-new-deployment`.

resource "aws_ecr_repository" "calcom" {
  name                 = "${var.name_prefix}-calcom"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "calcom" {
  repository = aws_ecr_repository.calcom.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire untagged images older than 7 days"
      selection = {
        tagStatus   = "untagged"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 7
      }
      action = { type = "expire" }
    }]
  })
}
