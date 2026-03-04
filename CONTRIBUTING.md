# Contributing

Thank you for your interest in contributing to this project.

## How to Contribute

1. Fork the repository.
2. Create a feature branch from `main`.
3. Make your changes.
4. Run `terraform fmt -recursive` to format your code.
5. Run `terraform validate` to check for errors.
6. Open a pull request against `main`.

## Guidelines

- Follow the existing code style and Terraform conventions.
- Keep changes focused. One pull request per feature or fix.
- Update `README.md` and variable descriptions when adding or changing inputs.
- Add entries to `CHANGELOG.md` under the `Unreleased` section.
- Do not commit `.tfvars` files containing real credentials or account-specific data.

## Reporting Issues

Open an issue with a clear description of the problem, the expected behavior, and
steps to reproduce. Include Terraform and provider version output when relevant.

## License

By contributing, you agree that your contributions will be licensed under the
MIT License.
