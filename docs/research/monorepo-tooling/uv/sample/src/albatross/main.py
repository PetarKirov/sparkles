"""Entry point wired to `uv run greet`, importing the local member."""

from bird_feeder import feed


def main() -> None:
    """Use the workspace-local `bird-feeder` member."""
    print(feed("albatross"))


if __name__ == "__main__":
    main()
