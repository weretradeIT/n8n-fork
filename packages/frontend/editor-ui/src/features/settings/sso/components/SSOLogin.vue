<script lang="ts" setup>
import { useSSOStore } from '../sso.store';
import { useI18n } from '@n8n/i18n';
import { useToast } from '@/app/composables/useToast';
import { useRoute } from 'vue-router';

const i18n = useI18n();
const ssoStore = useSSOStore();
const toast = useToast();
const route = useRoute();

const onSSOLogin = async () => {
	try {
		const redirectUrl = ssoStore.isDefaultAuthenticationSaml
			? await ssoStore.getSSORedirectUrl(
					typeof route.query?.redirect === 'string' ? route.query.redirect : '',
				)
			: ssoStore.oidc.loginUrl;
		window.location.href = redirectUrl ?? '';
	} catch (error) {
		toast.showError(error, 'Error', error.message);
	}
};
</script>

<template>
	<div v-if="ssoStore.showSsoLoginButton" :class="$style.ssoLogin">
		<div :class="$style.divider">
			<span>{{ i18n.baseText('sso.login.divider') }}</span>
		</div>
		<button class="wt-google-sso-button" @click="onSSOLogin">
			<div class="wt-google-sso-icon-wrapper">
				<img class="wt-google-sso-icon" src="../../../../../assets/shared/google.svg" alt="Google" />
			</div>
			<span class="wt-google-sso-text">{{ i18n.baseText('sso.login.button') }}</span>
		</button>
	</div>
</template>

<style src="../../../../../assets/shared/google-sso.css"></style>

<style lang="scss" module>
.ssoLogin {
	display: flex;
	flex-direction: column;
	justify-content: center;
	align-items: center;
	text-align: center;
}

.divider {
	width: 100%;
	position: relative;
	text-transform: uppercase;

	&::before {
		content: '';
		position: absolute;
		top: 50%;
		left: 0;
		width: 100%;
		height: 1px;
		background-color: var(--color--foreground);
	}

	span {
		position: relative;
		display: inline-block;
		margin: var(--spacing--2xs) auto;
		padding: var(--spacing--lg);
		background: var(--color--background--light-3);
	}
}
</style>

