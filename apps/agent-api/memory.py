"""Gerenciamento de memoria do agente — historico de conversas e contexto."""

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any


@dataclass
class Message:
    role: str
    content: str
    timestamp: datetime = field(default_factory=datetime.utcnow)
    metadata: dict[str, Any] = field(default_factory=dict)


class AgentMemory:
    """Memoria de curto prazo para o agente — mantém historico da sessao."""

    def __init__(self, max_messages: int = 20):
        self.messages: list[Message] = []
        self.max_messages = max_messages

    def add(self, role: str, content: str, **metadata) -> None:
        msg = Message(role=role, content=content, metadata=metadata)
        self.messages.append(msg)
        # sliding window — descarta mensagens mais antigas
        if len(self.messages) > self.max_messages:
            # preserva sempre a primeira (system prompt)
            self.messages = [self.messages[0]] + self.messages[-(self.max_messages - 1):]

    def to_langchain_format(self) -> list[dict]:
        return [{"role": m.role, "content": m.content} for m in self.messages]

    def clear(self) -> None:
        self.messages = []

    def __len__(self) -> int:
        return len(self.messages)
