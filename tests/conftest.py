import os
import pytest
from app import create_app
from app.models import Base


@pytest.fixture
def app(tmp_path):
    # TEST_DATABASE_URL must point at a disposable test database.
    application = create_app({
        "TESTING": True, "SECRET_KEY": "test-only-secret", "WORKFLOW_MODE": "local",
        "DATABASE_URL": os.environ.get("TEST_DATABASE_URL", f"sqlite:///{tmp_path / 'test.db'}"),
    })
    engine = application.extensions["engine"]
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    yield application
    Base.metadata.drop_all(engine)
    engine.dispose()


@pytest.fixture
def client(app):
    return app.test_client()
